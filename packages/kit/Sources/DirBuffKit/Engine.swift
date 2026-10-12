import DirBuffCore
import Foundation
import os

/// Manages folders, runs their rules while Temporary, and undoes what a run binned. Everything that
/// touches a user's file goes through here.
public struct Engine: Sendable {
  public let store: Store
  private static let logger = Logger(subsystem: "app.fishball.dirbuff", category: "engine")

  public init(store: Store) {
    self.store = store
  }

  public enum Failure: Error, Equatable {
    case folderNotFound(id: Int64)
    case journalEntryNotFound(id: Int64)
    case deletedPermanently
    case alreadyUndone
    /// The item changed after the run planned to remove it; the next run judges it again.
    case changedSincePlanned(String)
    /// The user emptied the Bin or took the item out themselves.
    case goneFromBin(String)
    /// Something new sits where the item was; undo never overwrites it.
    case originalPathTaken(String)
    /// A folder DirBuff never clears (`protectedRoots`), so it can't be added.
    case protectedFolder
  }

  /// A folder as its rules see it now: what a run would remove, and when the rest follows.
  public struct FolderStatus: Sendable {
    public var url: URL
    public var isTagged: Bool
    public var isProtectedRoot: Bool
    public var items: [Item]
    public var dueNow: [Removal]
    public var upcoming: [Upcoming]

    public init(
      url: URL,
      isTagged: Bool,
      isProtectedRoot: Bool,
      items: [Item],
      dueNow: [Removal],
      upcoming: [Upcoming]
    ) {
      self.url = url
      self.isTagged = isTagged
      self.isProtectedRoot = isProtectedRoot
      self.items = items
      self.dueNow = dueNow
      self.upcoming = upcoming
    }

    /// Everything in the folder, for the Size rule's "8.1 of 10 GB".
    public var size: Int64 { items.reduce(0) { $0 + $1.size } }
  }

  /// Items one run failed on. The rest of the run carries on.
  public struct RunResult: Sendable {
    public var journal: [JournalEntry]
    public var failures: [(item: Item, error: any Error)]
  }

  /// Adds a folder to DirBuff with default settings, untagged. If already added, returns the
  /// existing record.
  public func add(_ folder: URL, now: Date = Date()) throws -> Folder {
    if System.isProtected(folder) {
      throw Failure.protectedFolder
    }
    let canonical = try canonicalPath(of: folder)
    if let existing = try store.folder(path: canonical) {
      return existing
    }
    return try store.insert(
      Folder(
        bookmark: try folder.bookmarkData(),
        path: canonical,
        settings: TemporarySettings(),
        createdAt: now,
        lastRunAt: now
      ))
  }

  /// Sets or removes the Temporary tag. Turning it on resets `lastRunAt` so the folder's first run
  /// after being tagged never counts as the first run after a reboot. Either way the user has
  /// decided, so the folder no longer waits to be turned back on after a licence ended. A protected
  /// folder added before `add` refused one can't be turned on.
  public func setTemporary(_ folder: Folder, _ isOn: Bool, now: Date = Date()) throws {
    let (located, url) = try locate(folder)
    var updated = located
    if isOn {
      guard !System.isProtected(url) else { throw Failure.protectedFolder }
      try TemporaryTag.set(on: url)
      updated.lastRunAt = now
    } else {
      try TemporaryTag.remove(from: url)
    }
    updated.turnedOffByLicence = false
    try store.save(updated)
  }

  /// Removes the Temporary tag when the trial or licence ends, remembering the folder so buying
  /// can turn it back on in one click.
  public func turnOffByLicence(_ folder: Folder) throws {
    let (located, url) = try locate(folder)
    try TemporaryTag.remove(from: url)
    var updated = located
    updated.turnedOffByLicence = true
    try store.save(updated)
  }

  /// Untags the folder and forgets it, journal included.
  public func remove(_ folder: Folder) throws {
    let id = try require(folder.id)
    if let url = try? locate(folder).url { try TemporaryTag.remove(from: url) }
    try store.deleteFolder(id: id)
  }

  /// A folder's status. Removes nothing.
  public func status(folderID: Int64, now: Date = Date()) throws -> FolderStatus {
    let (folder, url) = try locate(folderID: folderID)
    return try status(
      of: url, isTagged: TemporaryTag.isSet(on: url), settings: folder.settings,
      lastRunAt: folder.lastRunAt, now: now)
  }

  /// Runs the folder's rules and journals what they removed. Run the folders on one volume one
  /// after another: each run reads free space after the last one freed some.
  public func run(folderID: Int64, now: Date = Date()) throws -> RunResult {
    let (folder, url) = try locate(folderID: folderID)
    let removals = try status(
      of: url, isTagged: TemporaryTag.isSet(on: url), settings: folder.settings,
      lastRunAt: folder.lastRunAt, now: now
    ).dueNow
    var result = RunResult(journal: [], failures: [])
    for removal in removals {
      // Removing earlier items can take a while; the user may untag the folder meanwhile.
      guard TemporaryTag.isSet(on: url) else { break }
      do {
        result.journal.append(try dispose(removal, of: folder, now: now))
      } catch {
        result.failures.append((removal.item, error))
        Self.logger.error(
          "Couldn't remove \(removal.item.url.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    var ran = folder
    ran.lastRunAt = now
    try store.save(ran)
    Self.logger.info("Removed \(result.journal.count) items, \(result.failures.count) failed")
    return result
  }

  /// Moves a binned item back to where it was.
  public func undo(journalEntryID: Int64, now: Date = Date()) throws {
    guard var entry = try store.journalEntry(id: journalEntryID) else {
      throw Failure.journalEntryNotFound(id: journalEntryID)
    }
    guard entry.undoneAt == nil else { throw Failure.alreadyUndone }
    guard let binnedPath = entry.binnedPath else { throw Failure.deletedPermanently }
    let original = try locate(folderID: entry.folderID).url.appendingPathComponent(entry.name)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: binnedPath) else { throw Failure.goneFromBin(binnedPath) }
    guard !fileManager.fileExists(atPath: original.path) else {
      throw Failure.originalPathTaken(original.path)
    }

    try fileManager.moveItem(at: URL(fileURLWithPath: binnedPath), to: original)
    entry.undoneAt = now
    try store.save(entry)
  }

  private func locate(folderID: Int64) throws -> (folder: Folder, url: URL) {
    guard let folder = try store.folder(id: folderID) else {
      throw Failure.folderNotFound(id: folderID)
    }
    return try locate(folder)
  }

  private func status(
    of url: URL,
    isTagged: Bool,
    settings: TemporarySettings,
    lastRunAt: Date,
    now: Date
  ) throws -> FolderStatus {
    let capacity = try System.capacity(of: url)
    let snapshot = FolderSnapshot(
      isTagged: isTagged,
      isProtectedRoot: System.isProtected(url),
      items: try Inventory.items(in: url)
    )
    let conditions = RunConditions(
      now: now,
      availableCapacity: capacity.available,
      totalCapacity: capacity.total,
      bootTime: try System.bootTime(),
      lastRunAt: lastRunAt
    )
    return FolderStatus(
      url: url,
      isTagged: snapshot.isTagged,
      isProtectedRoot: snapshot.isProtectedRoot,
      items: snapshot.items,
      dueNow: plan(snapshot, settings: settings, conditions: conditions),
      upcoming: upcoming(snapshot, settings: settings)
    )
  }

  /// Resolves the bookmark, recording where the folder now is if it moved.
  private func locate(_ folder: Folder) throws -> (folder: Folder, url: URL) {
    var isStale = false
    let url = try URL(resolvingBookmarkData: folder.bookmark, bookmarkDataIsStale: &isStale)
    guard isStale || url.path != folder.path else { return (folder, url) }

    var moved = folder
    moved.path = url.path
    moved.bookmark = try url.bookmarkData()
    try store.save(moved)
    return (moved, url)
  }

  private func dispose(_ removal: Removal, of folder: Folder, now: Date) throws
    -> JournalEntry
  {
    let url = removal.item.url
    guard try Inventory.item(at: url)?.freshness == removal.item.freshness else {
      throw Failure.changedSincePlanned(url.path)
    }
    let binned: URL? = try {
      switch folder.settings.disposal {
      case .bin:
        var binned: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &binned)
        return try require(binned as URL?)
      case .delete:
        try FileManager.default.removeItem(at: url)
        return nil
      }
    }()
    // ponytail: if this write fails after a successful bin, the item has no journal entry, but
    // Finder's Put Back still restores it. Un-park if a database error is ever seen.
    return try store.insert(
      JournalEntry(
        folderID: try require(folder.id),
        disposal: folder.settings.disposal,
        name: url.lastPathComponent,
        binnedPath: binned?.path,
        size: removal.item.size,
        reasons: removal.reasons,
        performedAt: now
      ))
  }
}

/// The path the bookmark resolves to: `/private/var/…` where the folder was given as `/var/…`.
public func canonicalPath(of url: URL) throws -> String {
  try url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? url.path
}

/// Unwraps a value that is present by construction: a saved record's id, `trashItem`'s result.
private func require<Value>(_ value: Value?) throws -> Value {
  guard let value else { throw MissingValue() }
  return value
}

private struct MissingValue: Error {}
