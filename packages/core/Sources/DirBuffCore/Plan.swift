import Foundation

public enum Rule: String, Sendable, Codable {
  case age
  case size
  case automatic
  case emptyOnRestart
}

/// An item the Temporary capability will dispose of, and every rule that chose it.
public struct Removal: Sendable, Equatable {
  public var item: Item
  public var reasons: Set<Rule>

  public init(item: Item, reasons: Set<Rule>) {
    self.item = item
    self.reasons = reasons
  }
}

/// What a Temporary folder looks like at the start of a run.
public struct FolderSnapshot: Sendable {
  /// False once the folder stops wearing Temporary: a plain folder is never cleaned.
  public var wearsTemporary: Bool
  public var isProtectedRoot: Bool
  public var items: [Item]

  public init(wearsTemporary: Bool, isProtectedRoot: Bool, items: [Item]) {
    self.wearsTemporary = wearsTemporary
    self.isProtectedRoot = isProtectedRoot
    self.items = items
  }
}

public struct RunConditions: Sendable {
  public var now: Date
  public var availableCapacity: Int64
  public var totalCapacity: Int64
  public var bootTime: Date
  public var lastRunAt: Date

  public init(
    now: Date,
    availableCapacity: Int64,
    totalCapacity: Int64,
    bootTime: Date,
    lastRunAt: Date
  ) {
    self.now = now
    self.availableCapacity = availableCapacity
    self.totalCapacity = totalCapacity
    self.bootTime = bootTime
    self.lastRunAt = lastRunAt
  }
}

/// The Automatic rule clears while free space is below this share of the volume, and stops once
/// clearing would bring it back.
public let automaticFreeSpaceThreshold = 0.10

/// Which items a Temporary folder's rules remove now, oldest first. An item with neither date is
/// never removed.
public func plan(
  _ folder: FolderSnapshot,
  settings: TemporarySettings,
  conditions: RunConditions
) -> [Removal] {
  guard folder.wearsTemporary, !folder.isProtectedRoot else { return [] }

  let oldestFirst = folder.items
    .compactMap { item in item.freshness.map { DatedItem(item: item, freshness: $0) } }
    .sorted {
      ($0.freshness, $0.item.url.lastPathComponent) < ($1.freshness, $1.item.url.lastPathComponent)
    }

  // Every rule removes a run of the oldest items, so each decides how many, and the longest run
  // goes.
  let counts: [Rule: Int] = [
    .age: settings.maxAgeDays.map { days in
      let cutoff = conditions.now.addingTimeInterval(-Double(days) * 86_400)
      return oldestFirst.prefix { $0.freshness < cutoff }.count
    },
    .emptyOnRestart: settings.emptyOnRestart && conditions.lastRunAt < conditions.bootTime
      ? oldestFirst.prefix { $0.freshness < conditions.bootTime }.count : nil,
    .size: settings.sizeLimit.map { limit in
      oldestFirst.count(toFree: folder.items.reduce(0) { $0 + $1.size } - limit)
    },
    .automatic: settings.automatic && settings.disposal == .delete
      ? oldestFirst.count(toFree: automaticShortfall(conditions)) : nil,
  ].compactMapValues(\.self)

  return oldestFirst.prefix(counts.values.max() ?? 0).enumerated().map { index, dated in
    Removal(item: dated.item, reasons: Set(counts.filter { index < $0.value }.keys))
  }
}

private struct DatedItem {
  var item: Item
  var freshness: Date
}

/// Bytes to free to bring the volume back to the threshold; zero or less when it has room.
private func automaticShortfall(_ conditions: RunConditions) -> Int64 {
  let target = Int64((Double(conditions.totalCapacity) * automaticFreeSpaceThreshold).rounded(.up))
  return target - conditions.availableCapacity
}

extension [DatedItem] {
  /// How many items from the front free at least `bytes`; all of them if even that falls short.
  fileprivate func count(toFree bytes: Int64) -> Int {
    var freed: Int64 = 0
    for (index, dated) in enumerated() {
      if freed >= bytes { return index }
      freed += dated.item.size
    }
    return count
  }
}
