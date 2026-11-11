import Foundation

extension BackupStatus {
  /// How many runs in a row fail before a backup says it is failing.
  public static let failingRunCount = 3
  /// How long every run may fail before a backup says it is failing.
  public static let failingDuration: TimeInterval = 3 * 3_600
  /// How long a folder may go without a good backup before it says so.
  public static let staleDuration: TimeInterval = 3 * 86_400

  /// Runs have failed several times in a row, or for hours on end.
  public func isFailing(now: Date) -> Bool {
    guard lastError != nil || failedRunsInARow > 0 else { return false }
    if failedRunsInARow >= Self.failingRunCount { return true }
    return failingSince.map { now.timeIntervalSince($0) >= Self.failingDuration } ?? false
  }

  /// No backup has finished for days, whatever the cause.
  public func isStale(now: Date) -> Bool {
    now.timeIntervalSince(lastSuccessAt ?? lastRunAt) >= Self.staleDuration
  }
}
