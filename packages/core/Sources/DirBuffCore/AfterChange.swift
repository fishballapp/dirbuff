import Foundation

/// Why Backup's owed runs are held back, in the order they are told when several apply.
public enum BackupHold: Sendable, Equatable, CaseIterable {
  case offline
  case expensiveNetwork
  case lowPowerMode
  case lowBattery

  /// What a row says while it waits.
  public var reason: String {
    switch self {
    case .offline: "Waiting for the internet"
    case .expensiveNetwork: "Waiting for Wi-Fi"
    case .lowPowerMode: "Low Power Mode"
    case .lowBattery: "On battery"
    }
  }
}

/// What the network offers right now.
public enum BackupNetwork: Sendable, Equatable {
  case offline
  /// Cellular, a Personal Hotspot or Low Data Mode (`isExpensive || isConstrained`).
  case expensive
  case unmetered
}

public enum BackupPower: Sendable, Equatable {
  /// On mains, or a Mac with no battery.
  case mains
  case battery(percent: Int)
}

/// What the Mac is like right now, which decides whether an owed backup may start.
public struct BackupConditions: Sendable, Equatable {
  /// Below this on battery, a backup waits.
  public static let batteryFloor = 20

  public var network: BackupNetwork
  public var isLowPowerMode: Bool
  public var power: BackupPower

  public init(network: BackupNetwork, isLowPowerMode: Bool, power: BackupPower) {
    self.network = network
    self.isLowPowerMode = isLowPowerMode
    self.power = power
  }

  /// A Mac on mains with a free connection: nothing holds anything.
  public static let clear = BackupConditions(
    network: .unmetered, isLowPowerMode: false, power: .mains)

  public var hold: BackupHold? {
    if network == .offline { return .offline }
    if network == .expensive { return .expensiveNetwork }
    if isLowPowerMode { return .lowPowerMode }
    if case .battery(let percent) = power, percent < Self.batteryFloor { return .lowBattery }
    return nil
  }
}

/// What `AfterChangeTimer` says to do next.
public enum AfterChangeStep: Sendable, Equatable {
  /// Ask the account whether Backup can still use it (a token refresh and `about.get`).
  case check
  /// Back this folder up; `dueAt` is when it became owed.
  case run(folderID: Int64, dueAt: Date)
  /// Thin the histories and prune (`BackupBuff.maintain`).
  case maintain
  /// Nothing to do now. Look again at `until`; nil when only a change of conditions, or of what
  /// the folders do, can alter it. `heldBy` is why an owed run is waiting, if one is.
  case wait(until: Date?, heldBy: BackupHold?)
}

/// When Backup's `.afterChange` schedule runs each folder, as a value: the driver feeds it what
/// happens and asks `next` what to do. It reads no clock; every method takes the time.
///
/// A folder is owed a run once it has changed and been quiet for `settle`, but no sooner than
/// `spacing` after its last run, or a day after its last run when nothing changed. An owed run is
/// still owed after the Mac sleeps or goes offline, so it runs on waking or reconnecting. The
/// folder owed longest goes first, one at a time.
public struct AfterChangeTimer: Sendable, Equatable {
  public let settle: TimeInterval
  public let spacing: TimeInterval
  public let check: TimeInterval
  /// How long a folder can go without a run, change or not.
  public let day: TimeInterval

  /// A folder the timer follows.
  public struct Followed: Sendable, Equatable {
    public var folderID: Int64
    /// When the folder was last backed up, or tried; nil when it never was, so it is owed at once.
    public var lastRunAt: Date?

    public init(folderID: Int64, lastRunAt: Date?) {
      self.folderID = folderID
      self.lastRunAt = lastRunAt
    }
  }

  private struct Entry: Sendable, Equatable {
    var lastRunAt: Date?
    /// When the folder last changed; nil while it hasn't since its last run began.
    var lastChangeAt: Date?
  }

  private var entries: [Int64: Entry] = [:]
  private var lastCheckAt: Date?
  private var lastMaintainedAt: Date?
  private var lastMaintainAttemptAt: Date?

  public init(
    settle: TimeInterval, spacing: TimeInterval, check: TimeInterval, day: TimeInterval = 86_400
  ) {
    self.settle = settle
    self.spacing = spacing
    self.check = check
    self.day = day
  }

  /// The timer for a buff's schedule; nil if it isn't `.afterChange`. `lastMaintainedAt` is when
  /// `maintain` last succeeded, kept across launches.
  public init?(_ schedule: BuffSchedule, lastMaintainedAt: Date? = nil) {
    guard case .afterChange(let settle, let spacing, let check) = schedule else { return nil }
    self.init(settle: settle.seconds, spacing: spacing.seconds, check: check.seconds)
    self.lastMaintainedAt = lastMaintainedAt
  }

  // MARK: - What happens

  /// The folders that wear Backup now. A folder the timer already follows keeps what it knows
  /// (its last run began here, which the store may not have recorded yet); one it didn't follow
  /// starts from `lastRunAt`; one that's gone is forgotten.
  public mutating func follow(_ folders: [Followed]) {
    let ids = Set(folders.map(\.folderID))
    entries = entries.filter { ids.contains($0.key) }
    for folder in folders where entries[folder.folderID] == nil {
      entries[folder.folderID] = Entry(lastRunAt: folder.lastRunAt, lastChangeAt: nil)
    }
  }

  public func follows(_ folderID: Int64) -> Bool { entries[folderID] != nil }

  /// Whether the timer follows any folder yet.
  public var followsAny: Bool { !entries.isEmpty }

  /// Every folder it follows is owed a run now, whatever it last did: `dirbuff://back-up-now`.
  /// The runs still wait for the Mac's conditions, and go oldest owed first, one at a time.
  public mutating func owedNow() {
    for id in entries.keys { entries[id] = Entry(lastRunAt: nil, lastChangeAt: .distantPast) }
  }

  /// The folder changed at `date`. A folder the timer doesn't follow is ignored.
  public mutating func changed(_ folderID: Int64, at date: Date) {
    guard var entry = entries[folderID] else { return }
    entry.lastChangeAt = max(entry.lastChangeAt ?? date, date)
    entries[folderID] = entry
  }

  /// A run of the folder began. What changes after this is for the next run.
  public mutating func began(_ folderID: Int64, at date: Date) {
    guard var entry = entries[folderID] else { return }
    entry.lastRunAt = date
    entry.lastChangeAt = nil
    entries[folderID] = entry
  }

  /// A run ended. One that failed leaves the folder owed again, no sooner than `spacing` after it
  /// began, so a failing folder is tried every `spacing`, not at once.
  public mutating func ended(_ folderID: Int64, succeeded: Bool) {
    guard !succeeded, var entry = entries[folderID], entry.lastChangeAt == nil else { return }
    entry.lastChangeAt = .distantPast
    entries[folderID] = entry
  }

  /// The check ran, whatever it found: it is asked again after `check`.
  public mutating func checked(at date: Date) {
    lastCheckAt = date
  }

  /// `maintain` ran; one that failed is tried again after `spacing`, not the next day.
  public mutating func maintained(at date: Date, succeeded: Bool) {
    lastMaintainAttemptAt = date
    if succeeded { lastMaintainedAt = date }
  }

  // MARK: - What to do

  /// When the folder is owed a run, or nil if the timer doesn't follow it. A past date means owed.
  public func dueAt(_ folderID: Int64, now: Date) -> Date? {
    guard let entry = entries[folderID] else { return nil }
    // A last run in the future (the clock was set back) counts as now.
    let lastRunAt = entry.lastRunAt.map { min($0, now) }
    let daily = lastRunAt.map { $0.addingTimeInterval(day) } ?? .distantPast
    guard let changedAt = entry.lastChangeAt else { return daily }
    let settled = changedAt.addingTimeInterval(settle)
    let spaced = lastRunAt.map { $0.addingTimeInterval(spacing) } ?? .distantPast
    return min(max(settled, spaced), daily)
  }

  /// The folders owed a run at `now`, the one owed longest first.
  public func owed(at now: Date) -> [(folderID: Int64, dueAt: Date)] {
    entries.keys
      .compactMap { id in dueAt(id, now: now).map { (folderID: id, dueAt: $0) } }
      .filter { $0.dueAt <= now }
      .sorted { ($0.dueAt, $0.folderID) < ($1.dueAt, $1.folderID) }
  }

  /// What to do at `now`. A check waits only for a connection; a run or `maintain` waits for
  /// every condition. `maintain` comes when no folder is owed, so it follows the day's backups.
  ///
  /// While the Google account is held (`isAccountHeld`: signed out, Drive full, the backup gone
  /// or in the Bin) no run or `maintain` starts, and none is wasted failing: they stay owed, and
  /// the check, which finds the cause gone, goes on, after which they run.
  public func next(
    now: Date, conditions: BackupConditions, isAccountHeld: Bool = false,
    calendar: Calendar = .current
  ) -> AfterChangeStep {
    let nextCheck = entries.isEmpty ? nil : lastCheckAt.map { $0.addingTimeInterval(check) }
    let isCheckDue = !entries.isEmpty && (nextCheck.map { $0 <= now } ?? true)
    if isCheckDue, conditions.network != .offline { return .check }

    let maintenance = maintenanceDue(now: now, calendar: calendar)
    let wakes =
      entries.keys.compactMap { dueAt($0, now: now) }
      + [nextCheck, maintenance.date]
      .compactMap(\.self)
    let wake = wakes.filter { $0 > now }.min()

    let hold = conditions.hold
    if let first = owed(at: now).first {
      guard hold == nil else { return .wait(until: wake, heldBy: hold) }
      guard !isAccountHeld else { return .wait(until: wake, heldBy: nil) }
      return .run(folderID: first.folderID, dueAt: first.dueAt)
    }
    guard maintenance == .now else { return .wait(until: wake, heldBy: nil) }
    return hold == nil && !isAccountHeld ? .maintain : .wait(until: wake, heldBy: nil)
  }

  private enum Maintenance: Equatable {
    case now
    case later(Date)

    var date: Date? {
      if case .later(let date) = self { date } else { nil }
    }
  }

  /// Once a day, at the first idle moment of it, and again after `spacing` if it failed.
  private func maintenanceDue(now: Date, calendar: Calendar) -> Maintenance {
    if let lastMaintainedAt, calendar.isDate(lastMaintainedAt, inSameDayAs: now) {
      let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
      return .later(tomorrow ?? now.addingTimeInterval(day))
    }
    if let retryAt = lastMaintainAttemptAt.map({ $0.addingTimeInterval(spacing) }), retryAt > now {
      return .later(retryAt)
    }
    return .now
  }
}

extension Duration {
  fileprivate var seconds: TimeInterval {
    TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }
}
