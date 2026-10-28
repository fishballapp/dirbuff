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
    /// The folder was deleted, moved to another disk, or moved to the Bin. Nothing acts on it until
    /// the user locates it.
    case folderMissing
    /// Locating a missing folder at one DirBuff already has would make two rules for one folder.
    case folderAlreadyAdded
    /// The folder chosen to locate a missing one is in the Bin.
    case folderInBin
  }

  /// How far a folder's run has got, reported before each item goes and once at the end.
  public struct RunProgress: Sendable, Equatable {
    public var folderID: Int64
    public var itemsDone: Int
    public var itemsTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// The name of the item going now; nil once the run is done.
    public var current: String?

    public init(
      folderID: Int64,
      itemsDone: Int,
      itemsTotal: Int,
      bytesDone: Int64,
      bytesTotal: Int64,
      current: String?
    ) {
      self.folderID = folderID
      self.itemsDone = itemsDone
      self.itemsTotal = itemsTotal
      self.bytesDone = bytesDone
      self.bytesTotal = bytesTotal
      self.current = current
    }

    /// How much of the run is done, from 0 to 1.
    public var fraction: Double {
      itemsTotal == 0 ? 1 : Double(itemsDone) / Double(itemsTotal)
    }
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
  /// after that never counts as the first run after a reboot. Turning it off forgets its settings,
  /// so adding Temporary again starts from the defaults. Either way the user has decided, so the
  /// folder no longer waits to be turned back on after a licence ended. A protected folder can't be
  /// turned on.
  public func setTemporary(_ folder: Folder, _ isOn: Bool, now: Date = Date()) throws {
    let folderID = try require(folder.id)
    var updated: Folder
    if isOn {
      let (located, url) = try locate(folderID: folderID)
      guard !System.isProtected(url) else { throw Failure.protectedFolder }
      updated = located
      updated.lastRunAt = now
    } else {
      // Turning off only writes the database, so it works on a folder DirBuff can't find.
      guard let stored = try store.folder(id: folderID) else {
        throw Failure.folderNotFound(id: folderID)
      }
      updated = stored
      updated.settings = TemporarySettings()
    }
    updated.wearsTemporary = isOn
    updated.turnedOffByLicence = false
    try store.save(updated)
  }

  /// Makes the folder plain when the trial or licence ends, remembering the folder so buying can
  /// turn it back on in one click, with its settings as they were. It writes only
  /// the database, so it works on a folder DirBuff can't reach, such as one on an unplugged drive.
  public func turnOffByLicence(_ folder: Folder) throws {
    let folderID = try require(folder.id)
    guard var updated = try store.folder(id: folderID) else {
      throw Failure.folderNotFound(id: folderID)
    }
    updated.wearsTemporary = false
    updated.turnedOffByLicence = true
    try store.save(updated)
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

  /// Points a missing folder at where the user found it. Refuses a protected folder, and one in
  /// the Bin, which would still be missing.
  public func relocate(folderID: Int64, to url: URL) throws {
    guard var folder = try store.folder(id: folderID) else {
      throw Failure.folderNotFound(id: folderID)
    }
    guard !System.isProtected(url) else { throw Failure.protectedFolder }
    let path = try canonicalPath(of: url)
    guard !Self.isInBin(path) else { throw Failure.folderInBin }
    guard try store.folder(path: path).map({ $0.id == folderID }) ?? true else {
      throw Failure.folderAlreadyAdded
    }
    folder.path = path
    folder.bookmark = try url.bookmarkData()
    folder.missingSince = nil
    try store.save(folder)
  }

  /// A folder's status. Removes no items.
  public func status(folderID: Int64, now: Date = Date()) throws -> FolderStatus {
    let (folder, url) = try locate(folderID: folderID)
    return try status(
      of: url, wearsTemporary: folder.wearsTemporary, settings: folder.settings,
      lastRunAt: folder.lastRunAt, now: now)
  }

  /// Runs the folder's rules and journals what they removed, under `runID` when the run is one
  /// clean-up's. Run the folders on one volume one after another: each run reads free space after
  /// the last one freed some. `progress` hears before each item goes and once at the end.
  public func run(
    folderID: Int64,
    now: Date = Date(),
    runID: Int64? = nil,
    progress: (RunProgress) -> Void = { _ in }
  ) throws -> RunResult {
    let (folder, url) = try locate(folderID: folderID)
    let removals = try status(
      of: url, wearsTemporary: folder.wearsTemporary, settings: folder.settings,
      lastRunAt: folder.lastRunAt, now: now
    ).dueNow
    var report = RunProgress(
      folderID: folderID, itemsDone: 0, itemsTotal: removals.count, bytesDone: 0,
      bytesTotal: removals.reduce(0) { $0 + $1.item.size }, current: nil)
    var result = RunResult(journal: [], failures: [])
    for removal in removals {
      // Removing earlier items can take a while; the user may take Temporary off meanwhile.
      guard try store.folder(id: folderID)?.wearsTemporary == true else { break }
      report.current = removal.item.url.lastPathComponent
      progress(report)
      defer {
        report.itemsDone += 1
        report.bytesDone += removal.item.size
      }
      do {
        result.journal.append(try dispose(removal, of: folder, runID: runID, now: now))
      } catch {
        result.failures.append((removal.item, error))
        Self.logger.error(
          "Couldn't remove \(removal.item.url.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    report.current = nil
    progress(report)
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
    let url: URL
    do {
      url = try URL(resolvingBookmarkData: folder.bookmark, bookmarkDataIsStale: &isStale)
    } catch {
      // An unplugged drive can't be resolved either; it isn't missing, just away.
      guard Self.isOnConnectedVolume(folder.path) else { throw error }
      throw Failure.folderMissing
    }
    // macOS tracks a folder moved to the Bin; following it there would clean inside the Bin.
    guard !Self.isInBin(url.path) else { throw Failure.folderMissing }
    // Once a folder has gone missing, a stale bookmark that resolves to its old path means macOS
    // fell back to the path: a new folder made there, not this one. It stays missing until the
    // user locates it. A folder put back from the Bin resolves by its identity, so it isn't stale.
    // ponytail: a folder renamed and replaced at its old path before DirBuff noticed it missing is
    // still followed to the new one. Rare; un-park if a user reports a rule on the wrong folder.
    guard !(isStale && url.path == folder.path && folder.missingSince != nil) else {
      throw Failure.folderMissing
    }
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

  private func dispose(_ removal: Removal, of folder: Folder, runID: Int64?, now: Date) throws
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
        runID: runID,
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

extension Engine {
  /// Whether a path is in a Bin: the user's (`~/.Trash`) or a drive's (`/Volumes/X/.Trashes`).
  static func isInBin(_ path: String) -> Bool {
    path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
  }

  /// Whether a path's drive is connected: always for a path on the startup disk.
  static func isOnConnectedVolume(_ path: String) -> Bool {
    let parts = path.split(separator: "/")
    guard parts.count >= 2, parts[0] == "Volumes" else { return true }
    return FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])")
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
