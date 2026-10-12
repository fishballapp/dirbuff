public enum Disposal: String, Sendable, Codable {
  /// Undoable, but frees no space until the Bin is emptied.
  case bin
  case delete
}

public struct TemporarySettings: Sendable, Equatable {
  /// The age a new folder starts with, and the one a re-ticked age rule comes back with.
  public static let defaultMaxAgeDays = 90

  /// Age rule: an item goes once it hasn't arrived or changed for this many days. Nil turns it off.
  public var maxAgeDays: Int?
  /// Size rule: the oldest items go until the folder fits. Nil turns it off.
  public var sizeLimit: Int64?
  /// Automatic rule: the oldest items go while the volume is low on space. Only acts with
  /// `.delete`: binning frees nothing, so it would bin the folder empty, run after run.
  public var automatic: Bool
  /// Empty on restart: the first run after a reboot clears what was there before it.
  public var emptyOnRestart: Bool
  public var disposal: Disposal

  public init(
    maxAgeDays: Int? = defaultMaxAgeDays,
    sizeLimit: Int64? = nil,
    automatic: Bool = false,
    emptyOnRestart: Bool = false,
    disposal: Disposal = .bin
  ) {
    self.maxAgeDays = maxAgeDays
    self.sizeLimit = sizeLimit
    self.automatic = automatic
    self.emptyOnRestart = emptyOnRestart
    self.disposal = disposal
  }
}
