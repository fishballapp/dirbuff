import Foundation

/// A capability a folder wears. A folder wears at most one of each, always listed in this order.
/// The raw value names the buff in the database.
public enum Buff: String, CaseIterable, Sendable, Codable {
  case temporary
  case backup
  case organise
  case search
}

/// How a buff's runs are timed. The app has a driver for each kind.
public enum BuffSchedule: Sendable, Equatable {
  /// On the hour, by the clock; an hour the Mac sleeps through is skipped. Temporary's: a forecast
  /// can then name the hour each item goes (`nextCleanUp`).
  case onTheHour
}

/// A folder's wear of one buff. The folder wears the buff while the buff's table has its row.
public struct Wear<Settings: Sendable & Equatable>: Sendable, Equatable {
  public var folderID: Int64
  public var settings: Settings
  /// The trial or licence ended: the buff stays on the folder, with its settings, but does
  /// nothing, and buying offers it back.
  public var isPausedByLicence: Bool
  /// When the buff last ran on the folder. Starts when it goes on, so its first run never counts
  /// as the first after a restart.
  public var lastRunAt: Date

  public init(folderID: Int64, settings: Settings, isPausedByLicence: Bool, lastRunAt: Date) {
    self.folderID = folderID
    self.settings = settings
    self.isPausedByLicence = isPausedByLicence
    self.lastRunAt = lastRunAt
  }
}
