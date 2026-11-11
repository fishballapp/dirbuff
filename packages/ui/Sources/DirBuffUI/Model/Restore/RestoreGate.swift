import Foundation

/// Which restore the app is running, so what a task that was cancelled or replaced finds when it
/// finishes can't touch the sheet of the restore that came after it.
public struct RestoreGate: Sendable, Equatable {
  public private(set) var current: UUID?

  public init() {}

  /// A new restore: any earlier one is no longer current.
  public mutating func begin() -> UUID {
    let run = UUID()
    current = run
    return run
  }

  /// Nothing is running: cancelled, closed or done.
  public mutating func end() { current = nil }

  /// Whether `run` is the restore running now.
  public func isCurrent(_ run: UUID) -> Bool { current == run }
}
