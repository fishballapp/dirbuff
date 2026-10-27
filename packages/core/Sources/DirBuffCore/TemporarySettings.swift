public enum Disposal: String, Sendable, Codable {
  /// Undoable, but frees no space until the Bin is emptied.
  case bin
  case delete
}

/// What a Temporary folder clears and how: one rule, and where things go.
public struct TemporarySettings: Sendable, Equatable {
  /// The age a new folder starts with.
  public static let defaultMaxAgeDays = 90
  /// The size the Size rule starts with when the folder has none yet.
  public static let defaultSizeLimit: Int64 = 10_000_000_000

  public var rule: Rule
  /// The Age rule's days: an item goes once it hasn't arrived or changed for this long. Kept while
  /// another rule is chosen, so choosing Age again brings it back.
  public var maxAgeDays: Int
  /// The Size rule's limit: the oldest items go until the folder fits. Kept like `maxAgeDays`.
  public var sizeLimit: Int64
  /// Where the Age, Size and Empty on restart rules send things.
  public var chosenDisposal: Disposal

  /// Where things go: as chosen, except that the Automatic rule always deletes. Binning frees
  /// nothing, so it would bin the folder empty, run after run.
  public var disposal: Disposal { rule == .automatic ? .delete : chosenDisposal }

  public init(
    rule: Rule = .age,
    maxAgeDays: Int = defaultMaxAgeDays,
    sizeLimit: Int64 = defaultSizeLimit,
    disposal: Disposal = .bin
  ) {
    self.rule = rule
    self.maxAgeDays = maxAgeDays
    self.sizeLimit = sizeLimit
    self.chosenDisposal = disposal
  }
}
