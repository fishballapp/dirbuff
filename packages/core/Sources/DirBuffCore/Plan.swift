import Foundation

/// What decides which things a Temporary folder clears. A folder has one.
public enum Rule: String, Sendable, Codable, CaseIterable {
  /// Things older than `maxAgeDays`.
  case age
  /// The oldest things, while the folder is over `sizeLimit`.
  case size
  /// The oldest things, while the disk is nearly full.
  case automatic
  /// Everything there before the Mac restarted, at the first clean-up after.
  case emptyOnRestart
}

/// An item Temporary will dispose of, and the rule that chose it.
public struct Removal: Sendable, Equatable {
  public var item: Item
  public var rule: Rule

  public init(item: Item, rule: Rule) {
    self.item = item
    self.rule = rule
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

/// Which items a Temporary folder's rule removes now, oldest first. An item with neither date is
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

  // Every rule removes a run of the oldest items; it decides how many.
  let count =
    switch settings.rule {
    case .age:
      oldestFirst.prefix {
        $0.freshness < conditions.now.addingTimeInterval(-Double(settings.maxAgeDays) * 86_400)
      }.count
    case .size:
      oldestFirst.count(toFree: folder.items.reduce(0) { $0 + $1.size } - settings.sizeLimit)
    case .automatic:
      oldestFirst.count(toFree: automaticShortfall(conditions))
    case .emptyOnRestart:
      conditions.lastRunAt < conditions.bootTime
        ? oldestFirst.prefix { $0.freshness < conditions.bootTime }.count : 0
    }

  return oldestFirst.prefix(count).map { Removal(item: $0.item, rule: settings.rule) }
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
