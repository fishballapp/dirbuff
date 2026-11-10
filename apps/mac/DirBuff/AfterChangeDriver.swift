import AppKit
import DirBuffCore
import DirBuffKit
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "backup")

/// A folder that wears Backup and can be reached now.
struct FollowedFolder: Sendable {
  var folderID: Int64
  var url: URL
  /// When it was last backed up or tried; nil if never, so it is owed at once.
  var lastRunAt: Date?
}

/// What the `.afterChange` driver does to the Mac and the account. `AppModel` supplies it.
@MainActor
protocol AfterChangeWork: AnyObject {
  /// Backup's licence gate, the one Temporary has: nothing runs, or is checked, while it's shut.
  var isAllowed: Bool { get }
  /// The folders that wear Backup and aren't paused, found now; an unplugged one is left out.
  func followedFolders() async -> [FollowedFolder]
  /// Backs the folder up; whether it did. `startedAt` is when the run begins.
  func backUp(folderID: Int64, startedAt: Date) async -> Bool
  func checkAccount() async
  /// Thins the histories and prunes; whether it did.
  func maintain() async -> Bool
}

/// Times Backup's runs (`BuffSchedule.afterChange`): an FSEvents stream per Backup folder marks it
/// changed, `AfterChangeTimer` says what is owed and when, and the driver does one thing at a time.
/// The timing is the timer's, and tested there; this holds the system's side of it.
@MainActor
final class AfterChangeDriver {
  /// After waking, the network takes a few seconds to come back; a run started at once would fail.
  static let wakeGrace: TimeInterval = 10

  private var timer: AfterChangeTimer
  private let work: any AfterChangeWork
  private var memory: BackupTriggerMemory
  private let now: @MainActor () -> Date
  private var conditions: BackupConditions
  private var monitor: BackupConditionsMonitor?
  private var streams: [Int64: (path: String, stream: FolderChangeStream)] = [:]
  /// Events up to this ID happened before a folder's run began, so the run saw them.
  private var seenUpTo: [Int64: UInt64] = [:]
  /// The ID each running folder began at, kept as its place once the run succeeds.
  private var beganAt: [Int64: FolderChangeStream.Place] = [:]
  private var wakeTimer: Timer?
  private var holdsUntil: Date?
  private var isWorking = false
  private var sleepAssertion: SleepAssertion?
  private var idleCallbacks: [@MainActor () -> Void] = []
  private let onHoldChange: @MainActor (BackupHold?) -> Void
  private(set) var hold: BackupHold?

  /// Nil if `schedule` isn't `.afterChange`.
  init?(
    schedule: BuffSchedule, work: any AfterChangeWork, memory: BackupTriggerMemory = .init(),
    now: @escaping @MainActor () -> Date = { Date() },
    onHoldChange: @escaping @MainActor (BackupHold?) -> Void = { _ in }
  ) {
    guard let timer = AfterChangeTimer(schedule, lastMaintainedAt: memory.maintainedAt) else {
      return nil
    }
    self.timer = timer
    self.work = work
    self.memory = memory
    self.now = now
    self.onHoldChange = onHoldChange
    conditions = BackupConditions(network: .offline, isLowPowerMode: false, power: .mains)
  }

  /// The driver lives as long as the app, so the observers below hold it strongly.
  func start() {
    let monitor = BackupConditionsMonitor { [self] conditions in
      self.conditions = conditions
      evaluate()
    }
    conditions = monitor.conditions
    monitor.start()
    self.monitor = monitor

    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
      _ in MainActor.assumeIsolated { self.wakeTimer?.invalidate() }
    }
    workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
      _ in
      MainActor.assumeIsolated {
        self.holdsUntil = self.now().addingTimeInterval(Self.wakeGrace)
        self.evaluate()
      }
    }
    for change in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
      NotificationCenter.default.addObserver(forName: change, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { self.evaluate() }
      }
    }
    Task { await reload() }
  }

  /// Whether a backup or `maintain` runs, so restic is working and the Mac is kept awake.
  private var isRunningRestic = false

  /// Calls `block` once nothing runs restic: now, if nothing does. Returns whether it waits.
  func whenIdle(_ block: @escaping @MainActor () -> Void) -> Bool {
    guard isRunningRestic else { return false }
    idleCallbacks.append(block)
    return true
  }

  // MARK: - Following

  /// Reads which folders wear Backup and watches each, after a folder was added, removed, moved
  /// or paused, or the licence changed.
  func reload() async {
    let folders = await work.followedFolders()
    timer.follow(folders.map { .init(folderID: $0.folderID, lastRunAt: $0.lastRunAt) })
    let wanted = Dictionary(
      folders.compactMap { folder in
        (try? canonicalPath(of: folder.url)).map { (folder.folderID, $0) }
      }, uniquingKeysWith: { first, _ in first })
    for (id, watched) in streams where wanted[id] != watched.path {
      watched.stream.stop()
      streams[id] = nil
    }
    for (id, path) in wanted where streams[id] == nil { watch(id, at: path) }
    seenUpTo = seenUpTo.filter { wanted[$0.key] != nil }
    evaluate()
  }

  /// A folder with no place to resume from is new here, or lost its journal: it counts as changed.
  private func watch(_ folderID: Int64, at path: String) {
    let uuid = FolderChangeStream.volumeUUID(ofPath: path)
    let place = memory.places[folderID].flatMap { $0.volumeUUID == uuid ? $0 : nil }
    guard
      let stream = FolderChangeStream(
        path: path, resuming: place?.eventID,
        onChange: { [weak self] eventID in
          Task { @MainActor in self?.folderChanged(folderID, eventID: eventID) }
        })
    else {
      // The daily run still backs it up.
      logger.error("Couldn't watch folder \(folderID)")
      return
    }
    streams[folderID] = (path, stream)
    if place == nil { timer.changed(folderID, at: now()) }
  }

  private func folderChanged(_ folderID: Int64, eventID: UInt64) {
    if let seen = seenUpTo[folderID], eventID <= seen { return }
    timer.changed(folderID, at: now())
    evaluate()
  }

  // MARK: - Doing

  /// Asks the timer what is owed and does it, or sleeps until something is.
  func evaluate() {
    wakeTimer?.invalidate()
    guard !isWorking else { return }
    let now = now()
    if let holdsUntil, holdsUntil > now {
      arm(at: holdsUntil)
      return
    }
    guard work.isAllowed else {
      setHold(nil)
      return
    }
    switch timer.next(now: now, conditions: conditions) {
    case .wait(let until, let heldBy):
      setHold(heldBy)
      if let until { arm(at: until) }
    case .check:
      perform(isRunningRestic: false) {
        await self.work.checkAccount()
        self.timer.checked(at: self.now())
      }
    case .run(let folderID, _):
      setHold(nil)
      perform(isRunningRestic: true) { await self.backUp(folderID) }
    case .maintain:
      setHold(nil)
      perform(isRunningRestic: true) {
        let isDone = await self.work.maintain()
        self.timer.maintained(at: self.now(), succeeded: isDone)
        if isDone { self.memory.maintainedAt = self.now() }
      }
    }
  }

  private func backUp(_ folderID: Int64) async {
    let startedAt = now()
    timer.began(folderID, at: startedAt)
    let id = FolderChangeStream.currentEventID()
    seenUpTo[folderID] = id
    let isDone = await work.backUp(folderID: folderID, startedAt: startedAt)
    timer.ended(folderID, succeeded: isDone)
    // The place is kept only when the backup is: after a failure, a relaunch finds this
    // folder's changes since the last good backup again.
    guard isDone, let watched = streams[folderID],
      let uuid = FolderChangeStream.volumeUUID(ofPath: watched.path)
    else { return }
    var places = memory.places
    places[folderID] = .init(eventID: id, volumeUUID: uuid)
    memory.places = places
  }

  private func perform(isRunningRestic isRestic: Bool, _ job: @escaping @MainActor () async -> Void)
  {
    isWorking = true
    isRunningRestic = isRestic
    sleepAssertion = isRestic ? SleepAssertion(reason: "DirBuff is backing up your folders") : nil
    Task {
      await job()
      isWorking = false
      isRunningRestic = false
      sleepAssertion = nil
      let callbacks = idleCallbacks
      idleCallbacks = []
      for callback in callbacks { callback() }
      evaluate()
    }
  }

  private func arm(at date: Date) {
    let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
      Task { @MainActor in self.evaluate() }
    }
    RunLoop.main.add(timer, forMode: .common)
    wakeTimer = timer
  }

  private func setHold(_ newHold: BackupHold?) {
    guard newHold != hold else { return }
    hold = newHold
    onHoldChange(newHold)
  }
}
