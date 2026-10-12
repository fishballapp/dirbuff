import Foundation

/// What DirBuff knows about its licence: when the trial started and, once a key is entered, this
/// Mac's activation and Polar's last answer. One row in the database.
public struct LicenceRecord: Sendable, Equatable {
  public var trialStartedAt: Date
  public var key: String?
  /// Kept with the key, so a reinstall reuses this Mac's activation instead of taking another.
  public var activationID: String?
  /// When Polar last said the licence holds. The offline grace counts from here.
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

  /// A good answer from Polar holds for a day: its public endpoints allow only a few calls a
  /// minute. Until one comes, every run asks again.
  public func isCheckDue(now: Date) -> Bool {
    key != nil && !hasEnded
      && now.timeIntervalSince(lastCheckedAt ?? .distantPast) >= Licence.checkInterval
  }
}

/// Whether DirBuff may clean, and what it tells the user.
public enum Licence: Sendable, Equatable {
  /// `daysLeft` counts calendar days to the trial's end: 1 is tomorrow, 0 today.
  case trial(daysLeft: Int)
  case trialEnded
  case licensed
  /// Licensed, but Polar hasn't been reached for the offline grace. The next good check resumes.
  case paused
  case ended

  public static let trialLength: TimeInterval = 14 * 86_400
  public static let offlineGrace: TimeInterval = 14 * 86_400
  public static let checkInterval: TimeInterval = 86_400

  public init(_ record: LicenceRecord, now: Date, calendar: Calendar = .current) {
    if record.hasEnded {
      self = .ended
    } else if record.key != nil {
      let lastChecked = record.lastCheckedAt ?? .distantPast
      self = now.timeIntervalSince(lastChecked) < Self.offlineGrace ? .licensed : .paused
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
    case .trial, .licensed: true
    case .trialEnded, .paused, .ended: false
    }
  }

  /// Only an end Polar or the trial confirmed takes the folders' tags away. Being offline only
  /// pauses: a paying customer away from the internet mustn't have to set their folders up again.
  public var plainsFolders: Bool {
    switch self {
    case .trialEnded, .ended: true
    case .trial, .licensed, .paused: false
    }
  }
}
