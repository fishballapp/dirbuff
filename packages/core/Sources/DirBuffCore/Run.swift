import Foundation

/// What a buff's run on one folder is part of, and whom it tells how far it has got.
public struct RunContext: Sendable {
  /// The History run it belongs to; nil if the run couldn't be recorded.
  public var runID: Int64?
  /// When the run was due, which it counts from: a clean-up removes what the forecast said would
  /// go at that hour, however late the timer fired.
  public var scheduledAt: Date
  /// Hears before each item and once at the end.
  public var progress: @Sendable (RunProgress) -> Void

  public init(
    runID: Int64?,
    scheduledAt: Date,
    progress: @escaping @Sendable (RunProgress) -> Void = { _ in }
  ) {
    self.runID = runID
    self.scheduledAt = scheduledAt
    self.progress = progress
  }
}

/// How far a folder's run has got.
public struct RunProgress: Sendable, Equatable {
  public var folderID: Int64
  public var itemsDone: Int
  public var itemsTotal: Int
  public var bytesDone: Int64
  public var bytesTotal: Int64
  /// The name of the item being worked on; nil before the first and once the run is done.
  public var current: String?

  public init(
    folderID: Int64,
    itemsDone: Int,
    itemsTotal: Int,
    bytesDone: Int64,
    bytesTotal: Int64,
    current: String?
  ) {
    self.folderID = folderID
    self.itemsDone = itemsDone
    self.itemsTotal = itemsTotal
    self.bytesDone = bytesDone
    self.bytesTotal = bytesTotal
    self.current = current
  }

  /// How much of the run is done, from 0 to 1.
  public var fraction: Double {
    itemsTotal == 0 ? 1 : Double(itemsDone) / Double(itemsTotal)
  }
}

/// What one buff's run on one folder did.
public struct RunSummary: Sendable, Equatable {
  public var items: Int
  public var bytes: Int64
  /// Items it couldn't do. The rest of the run carried on.
  public var failures: Int

  public init(items: Int, bytes: Int64, failures: Int) {
    self.items = items
    self.bytes = bytes
    self.failures = failures
  }
}
