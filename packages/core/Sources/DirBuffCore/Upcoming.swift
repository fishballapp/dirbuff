import Foundation

/// An item and when the Age rule will find it due; it goes at the clean-up after (`nextCleanUp`).
public struct Upcoming: Sendable, Equatable {
  public var item: Item
  public var date: Date

  public init(item: Item, date: Date) {
    self.item = item
    self.date = date
  }
}

/// When the Age rule will remove each item if nothing changes, soonest first. Only Age has a date:
/// Size and Automatic depend on what arrives and on the disk, and Empty on restart on the next
/// restart, so the folder's settings and state speak for those.
public func upcoming(_ folder: FolderSnapshot, settings: TemporarySettings) -> [Upcoming] {
  guard folder.wearsTemporary, !folder.isProtectedRoot, let days = settings.maxAgeDays else {
    return []
  }
  return folder.items
    .compactMap { item in
      item.freshness.map {
        Upcoming(item: item, date: $0.addingTimeInterval(Double(days) * 86_400))
      }
    }
    .sorted { ($0.date, $0.item.url.lastPathComponent) < ($1.date, $1.item.url.lastPathComponent) }
}
