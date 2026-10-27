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
    /// Temporary wasn't taken off this folder, or the day it could be put back has passed.
    case cannotPutBack
  }

  /// A folder as its rules see it now: what a run would remove, and when the rest follows.
  public struct FolderStatus: Sendable {
    public var url: URL
    public var wearsTemporary: Bool
    public var isProtectedRoot: Bool
    public var items: [Item]
    public var dueNow: [Removal]
    public var upcoming: [Upcoming]

    public init(
      url: URL,
      wearsTemporary: Bool,
      isProtectedRoot: Bool,
      items: [Item],
      dueNow: [Removal],
      upcoming: [Upcoming]
    ) {
      self.url = url
      self.wearsTemporary = wearsTemporary
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

  /// Adds a folder to DirBuff with default settings, not Temporary. If already added, returns the
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

  /// Makes the folder Temporary or plain. Turning it on resets `lastRunAt` so the folder's first run
  /// after that never counts as the first run after a reboot. Turning it off records when, so it
  /// can be put back for a day (`Folder.putBackUntil`). Either way the user has decided, so the folder no
  /// longer waits to be turned back on after a licence ended. A protected folder can't be turned on.
  public func setTemporary(_ folder: Folder, _ isOn: Bool, now: Date = Date()) throws {
    let (located, url) = try locate(folderID: try require(folder.id))
    var updated = located
    if isOn {
      guard !System.isProtected(url) else { throw Failure.protectedFolder }
      updated.lastRunAt = now
      updated.takenOffAt = nil
    } else if updated.wearsTemporary {
      updated.takenOffAt = now
    }
    updated.wearsTemporary = isOn
    updated.turnedOffByLicence = false
    try store.save(updated)
  }

  /// Makes the folder plain when the trial or licence ends, remembering the folder so buying can
  /// turn it back on in one click. Unlike a user's switch-off, this can't be put back. It writes only
  /// the database, so it works on a folder DirBuff can't reach, such as one on an unplugged drive.
  public func turnOffByLicence(_ folder: Folder) throws {
    let folderID = try require(folder.id)
    guard var updated = try store.folder(id: folderID) else {
      throw Failure.folderNotFound(id: folderID)
    }
    updated.wearsTemporary = false
    updated.takenOffAt = nil
    updated.turnedOffByLicence = true
    try store.save(updated)
  }

  /// Whether Temporary taken off this folder by the user can still be put back at `now`.
  public func canPutBack(_ folder: Folder, now: Date = Date()) -> Bool {
    folder.putBackUntil.map { now < $0 } ?? false
  }

  /// Turns Temporary back on with the folder's settings unchanged, if `canPutBack` allows it.
  public func putBack(_ folder: Folder, now: Date = Date()) throws {
    let (located, _) = try locate(folderID: try require(folder.id))
    guard canPutBack(located, now: now) else { throw Failure.cannotPutBack }
    try setTemporary(located, true, now: now)
  }

  /// Saves the folder's settings only. The folder may be a copy from before a Temporary switch or a
  /// licence change, so nothing else is written. Choosing Empty on restart counts from `now`, as
  /// turning Temporary on does.
  public func saveSettings(_ settings: TemporarySettings, for folder: Folder, now: Date = Date())
    throws
  {
    try store.saveSettings(settings, folderID: try require(folder.id), now: now)
  }

  /// Forgets the folder and its journal. The folder's files are left alone.
  public func remove(_ folder: Folder) throws {
    try store.deleteFolder(id: try require(folder.id))
  }

  /// A folder's status. Removes no items.
  public func status(folderID: Int64, now: Date = Date()) throws -> FolderStatus {
    let (folder, url) = try locate(folderID: folderID)
    return try status(
      of: url, wearsTemporary: folder.wearsTemporary, settings: folder.settings,
      lastRunAt: folder.lastRunAt, now: now)
  }

  /// Runs the folder's rules and journals what they removed. Run the folders on one volume one
  /// after another: each run reads free space after the last one freed some.
  public func run(folderID: Int64, now: Date = Date()) throws -> RunResult {
    let (folder, url) = try locate(folderID: folderID)
    let removals = try status(
      of: url, wearsTemporary: folder.wearsTemporary, settings: folder.settings,
      lastRunAt: folder.lastRunAt, now: now
    ).dueNow
    var result = RunResult(journal: [], failures: [])
    for removal in removals {
      // Removing earlier items can take a while; the user may take Temporary off meanwhile.
      guard try store.folder(id: folderID)?.wearsTemporary == true else { break }
      do {
        result.journal.append(try dispose(removal, of: folder, now: now))
      } catch {
        result.failures.append((removal.item, error))
        Self.logger.error(
          "Couldn't remove \(removal.item.url.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    try store.recordRun(folderID: folderID, at: now)
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

  private func status(
    of url: URL,
    wearsTemporary: Bool,
    settings: TemporarySettings,
    lastRunAt: Date,
    now: Date
  ) throws -> FolderStatus {
    let capacity = try System.capacity(of: url)
    let snapshot = FolderSnapshot(
      wearsTemporary: wearsTemporary,
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
      wearsTemporary: snapshot.wearsTemporary,
      isProtectedRoot: snapshot.isProtectedRoot,
      items: snapshot.items,
      dueNow: plan(snapshot, settings: settings, conditions: conditions),
      upcoming: upcoming(snapshot, settings: settings)
    )
  }

  /// Reads the folder from the database and resolves its bookmark, recording where the folder now
  /// is if it moved. A folder still owing its legacy tag's removal takes that first, so nothing
  /// acts on a folder before its Temporary setting is in the database.
  private func locate(folderID: Int64) throws -> (folder: Folder, url: URL) {
    guard var folder = try store.folder(id: folderID) else {
      throw Failure.folderNotFound(id: folderID)
    }
    var isStale = false
    let url = try URL(resolvingBookmarkData: folder.bookmark, bookmarkDataIsStale: &isStale)
    if isStale || url.path != folder.path {
      folder.path = url.path
      folder.bookmark = try url.bookmarkData()
      try store.save(folder)
    }
    guard try store.hasLegacyTag(folderID: folderID) else { return (folder, url) }
    try takeOffLegacyTag(folderID: folderID, at: url)
    return (try require(store.folder(id: folderID)), url)
  }

  /// Sets the folder's Temporary from its legacy tag, then takes the tag off. The setting is written
  /// first: a crash between the two leaves a tag nothing reads, where the other order could lose
  /// the setting. A folder that can't be read throws and stays pending.
  private func takeOffLegacyTag(folderID: Int64, at url: URL) throws {
    let hadTag = try LegacyTemporaryTag.isSet(on: url)
    guard try store.finishLegacyTag(folderID: folderID, hadTag: hadTag) else { return }
    do {
      try LegacyTemporaryTag.remove(from: url)
    } catch {
      // ponytail: if removing the tag fails, it stays on the folder, where Finder shows it, but
      // nothing reads it. Un-park if a user reports the tag still showing.
      Self.logger.error(
        "Couldn't take the old tag off \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
      )
    }
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
        reasons: [removal.rule],
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
