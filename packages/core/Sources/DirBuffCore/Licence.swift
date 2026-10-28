import Foundation

/// What DirBuff knows about its licence: when the trial started and, once a key is entered, this
/// Mac's activation and Polar's last answer. One row in the database.
public struct LicenceRecord: Sendable, Equatable {
  public var trialStartedAt: Date
  public var key: String?
  /// Kept with the key, so a reinstall reuses this Mac's activation instead of taking another.
  public var activationID: String?
  /// When Polar last said the licence holds. Its day is the last one the licence was paid up: the
  /// newest version it covers came out on or before it.
  public var lastCheckedAt: Date?
  /// Polar said the licence no longer holds: cancelled, refunded, or this Mac's activation removed.
  public var hasEnded: Bool

  public init(
    trialStartedAt: Date,
    key: String? = nil,
    activationID: String? = nil,
    lastCheckedAt: Date? = nil,
    hasEnded: Bool = false
  ) {
    self.trialStartedAt = trialStartedAt
    self.key = key
    self.activationID = activationID
    self.lastCheckedAt = lastCheckedAt
    self.hasEnded = hasEnded
  }

  /// Whether a version released on `release` (a day, as `ReleaseDay` reads it) came out while the
  /// licence was paid up: on or before the last day Polar confirmed the key.
  public func covers(release: ReleaseDay) -> Bool {
    guard let lastCheckedAt else { return false }
    return release <= ReleaseDay(containing: lastCheckedAt)
  }

  /// Only an ended licence limits the updates offered: a paying customer, and someone still on
  /// the trial, may take the newest. Once it has ended, only the versions it covered.
  public var limitsUpdates: Bool { hasEnded }

  /// The `releases` this licence covers, by release day; an undated one is not covered. Which of
  /// them is newest is the caller's to say: several come out on one day (a release and a dev build).
  public func covered<Release>(
    _ releases: [Release], releasedOn day: (Release) -> ReleaseDay?
  ) -> [Release] {
    releases.filter { release in day(release).map(covers(release:)) ?? false }
  }

  /// A good answer from Polar holds for a day: its public endpoints allow only a few calls a
  /// minute. A build the last answer doesn't cover is asked about on every run, since it is paused
  /// until an answer comes. Until one comes, every run asks again.
  public func isCheckDue(now: Date, release: ReleaseDay) -> Bool {
    guard key != nil, !hasEnded else { return false }
    return !covers(release: release)
      || now.timeIntervalSince(lastCheckedAt ?? .distantPast) >= Licence.checkInterval
  }

  /// Whether Sparkle may download and install a build released on `release`, given this record as
  /// it stands. A trial installs (there is no key to confirm); a key needs a confirmation that covers
  /// the build. Polar having ended the key refuses it; a key not yet confirmed for it waits for one.
  public func gate(installing release: ReleaseDay?) -> UpdateGate {
    guard key != nil else { return .install }
    if let release, covers(release: release) { return .install }
    return hasEnded ? .refuse : .wait
  }
}

/// What Sparkle does with an update that is ready to install.
public enum UpdateGate: Sendable, Equatable {
  case install
  /// No confirmation covers the build yet: don't download it, ask Polar, and check again.
  case wait
  /// The licence ended before this build came out: don't download it.
  case refuse
}

/// Whether DirBuff may clean, and what it tells the user.
public enum Licence: Sendable, Equatable {
  /// `daysLeft` counts calendar days to the trial's end: 1 is tomorrow, 0 today.
  case trial(daysLeft: Int)
  case trialEnded
  case licensed
  /// Licensed, but this version came out after Polar last confirmed the key, so it isn't covered
  /// until a check does. Cleaning stops and the folders stay as they are; the next good check
  /// resumes it by itself.
  case paused
  /// The licence ended, but this version came out while it was paid up (`paidThrough` is the last
  /// day Polar confirmed it): it keeps working, with no end.
  case kept(paidThrough: Date)
  /// The licence ended before this version came out. `paidThrough` is nil if Polar never confirmed it.
  case ended(paidThrough: Date?)

  public static let trialLength: TimeInterval = 14 * 86_400
  public static let checkInterval: TimeInterval = 86_400

  /// `release` is the day this version came out. A version the paid years covered works for good:
  /// once the licence has ended, and offline too, since a payment already made can't be taken back.
  /// A version the last answer doesn't cover waits for the next answer, without cleaning until then.
  public init(
    _ record: LicenceRecord, now: Date, release: ReleaseDay, calendar: Calendar = .current
  ) {
    if record.hasEnded {
      if let paidThrough = record.lastCheckedAt, record.covers(release: release) {
        self = .kept(paidThrough: paidThrough)
      } else {
        self = .ended(paidThrough: record.lastCheckedAt)
      }
    } else if record.key != nil {
      self = record.covers(release: release) ? .licensed : .paused
    } else {
      let end = record.trialStartedAt.addingTimeInterval(Self.trialLength)
      let daysLeft = calendar.dateComponents(
        [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: end)
      ).day
      self = now < end ? .trial(daysLeft: daysLeft ?? 0) : .trialEnded
    }
  }

  public var mayClean: Bool {
    switch self {
    case .trial, .licensed, .kept: true
    case .trialEnded, .paused, .ended: false
    }
  }

  /// Only an end the trial or Polar confirmed takes Temporary off the folders. A pause doesn't: the
  /// folders wait as they are until a check resumes them.
  public var plainsFolders: Bool {
    switch self {
    case .trialEnded, .ended: true
    case .trial, .licensed, .paused, .kept: false
    }
  }
}
