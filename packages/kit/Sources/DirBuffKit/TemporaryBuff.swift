import DirBuffCore
import Foundation
import os

/// Temporary: clears what the folder's rule chooses, on the hour, and puts back what it binned.
/// With undo, everything that touches a user's file goes through here.
public struct TemporaryBuff: BuffModule {
  public let engine: Engine
  private var store: Store { engine.store }
  private static let logger = Logger(subsystem: "app.fishball.dirbuff", category: "temporary")

  public init(engine: Engine) {
    self.engine = engine
  }

  public enum Failure: Error, Equatable {
    case journalEntryNotFound(id: Int64)
    case deletedPermanently
    case alreadyUndone
    /// The item changed after the run planned to remove it; the next run judges it again.
    case changedSincePlanned(String)
    /// The user emptied the Bin or took the item out themselves.
    case goneFromBin(String)
    /// Something new sits where the item was; undo never overwrites it.
    case originalPathTaken(String)
  }

  public var buff: Buff { .temporary }
  public var schedule: BuffSchedule { .onTheHour }
  public var defaultSettings: TemporarySettings { TemporarySettings() }

  /// Temporary judges each top-level item, so on a folder whose items are the Mac's own (home,
  /// Library, a drive's root) it would break things rather than tidy them.
  public func refusal(for url: URL) -> Refusal? {
    System.isProtected(url) ? .protectedFolder : nil
  }

  public func wear(folderID: Int64) throws -> Wear<TemporarySettings>? {
    try store.temporaryWear(folderID: folderID)
  }

  public func wearers() throws -> [Wear<TemporarySettings>] {
    try store.temporaryWearers()
  }

  /// Finds the folder first, to refuse a protected one. Its runs count from `now`, so its first
  /// never counts as the first after a restart.
  public func putOn(folderID: Int64, now: Date = Date()) throws {
    if let refusal = refusal(for: try engine.locate(folderID: folderID).url) { throw refusal }
    try store.putOnTemporary(folderID: folderID, settings: defaultSettings, now: now)
  }

  /// Choosing Empty on restart counts from `now`, as putting Temporary on does.
  public func save(_ settings: TemporarySettings, folderID: Int64, now: Date = Date()) throws {
    try store.saveTemporarySettings(settings, folderID: folderID, now: now)
  }

  public func takeOff(folderID: Int64) throws {
    try store.takeOffTemporary(folderID: folderID)
  }

  public func setPausedByLicence(_ isPaused: Bool, folderID: Int64) throws {
    try store.setTemporaryPausedByLicence(isPaused, folderID: folderID)
  }

  /// What the folder's rule would remove now, and when the rest follows. A folder the licence
  /// paused is still listed, but nothing in it is due.
  public func read(_ folder: LocatedFolder, _ wear: Wear<TemporarySettings>, now: Date = Date())
    throws -> TemporaryStatus
  {
    let url = folder.url
    let capacity = try System.capacity(of: url)
    let snapshot = FolderSnapshot(
      wearsTemporary: !wear.isPausedByLicence,
      isProtectedRoot: System.isProtected(url),
      items: try Inventory.items(in: url)
    )
    let conditions = RunConditions(
      now: now,
      availableCapacity: capacity.available,
      totalCapacity: capacity.total,
      bootTime: try System.bootTime(),
      lastRunAt: wear.lastRunAt
    )
    return TemporaryStatus(
      url: url,
      wearsTemporary: snapshot.wearsTemporary,
      isProtectedRoot: snapshot.isProtectedRoot,
      items: snapshot.items,
      dueNow: plan(snapshot, settings: wear.settings, conditions: conditions),
      upcoming: upcoming(snapshot, settings: wear.settings)
    )
  }

  /// Removes what the rule chooses and journals it under the context's run. Run the folders on one
  /// volume one after another: each run reads free space after the last one freed some.
  public func run(
    _ folder: LocatedFolder, _ wear: Wear<TemporarySettings>, context: RunContext
  ) throws -> RunSummary {
    let now = context.scheduledAt
    let removals = try read(folder, wear, now: now).dueNow
    var report = RunProgress(
      folderID: wear.folderID, itemsDone: 0, itemsTotal: removals.count, bytesDone: 0,
      bytesTotal: removals.reduce(0) { $0 + $1.item.size }, current: nil)
    var summary = RunSummary(items: 0, bytes: 0, failures: 0)
    for removal in removals {
      // Removing earlier items can take a while; the user may take Temporary off meanwhile, or
      // the licence pause it.
      guard try store.temporaryWear(folderID: wear.folderID)?.isPausedByLicence == false else {
        break
      }
      report.current = removal.item.url.lastPathComponent
      context.progress(report)
      defer {
        report.itemsDone += 1
        report.bytesDone += removal.item.size
      }
      do {
        let entry = try dispose(
          removal, from: wear.folderID, to: wear.settings.disposal, runID: context.runID, now: now)
        summary.items += 1
        summary.bytes += entry.size
      } catch {
        summary.failures += 1
        Self.logger.error(
          "Couldn't remove \(removal.item.url.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    report.current = nil
    context.progress(report)
    try store.recordTemporaryRun(folderID: wear.folderID, at: now)
    Self.logger.info("Removed \(summary.items) items, \(summary.failures) failed")
    return summary
  }

  /// Moves a binned item back to where it was.
  public func undo(journalEntryID: Int64, now: Date = Date()) throws {
    guard var entry = try store.journalEntry(id: journalEntryID) else {
      throw Failure.journalEntryNotFound(id: journalEntryID)
    }
    guard entry.undoneAt == nil else { throw Failure.alreadyUndone }
    guard let binnedPath = entry.binnedPath else { throw Failure.deletedPermanently }
    let original = try engine.locate(folderID: entry.folderID).url
      .appendingPathComponent(entry.name)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: binnedPath) else { throw Failure.goneFromBin(binnedPath) }
    guard !fileManager.fileExists(atPath: original.path) else {
      throw Failure.originalPathTaken(original.path)
    }

    try fileManager.moveItem(at: URL(fileURLWithPath: binnedPath), to: original)
    entry.undoneAt = now
    try store.save(entry)
  }

  private func dispose(
    _ removal: Removal, from folderID: Int64, to disposal: Disposal, runID: Int64?, now: Date
  ) throws -> JournalEntry {
    let url = removal.item.url
    guard try Inventory.item(at: url)?.freshness == removal.item.freshness else {
      throw Failure.changedSincePlanned(url.path)
    }
    let binned: URL? = try {
      switch disposal {
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
        folderID: folderID,
        disposal: disposal,
        name: url.lastPathComponent,
        binnedPath: binned?.path,
        size: removal.item.size,
        reasons: [removal.rule],
        performedAt: now
      ))
  }
}

/// A folder as Temporary's rule sees it now: what a run would remove, and when the rest follows.
public struct TemporaryStatus: Sendable {
  public var url: URL
  /// False while the licence pauses it: nothing is due.
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
