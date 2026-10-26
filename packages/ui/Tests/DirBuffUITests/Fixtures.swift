import DirBuffCore
import DirBuffKit
import Foundation

@testable import DirBuffUI

/// Reports and items both suites build their states from.
let oneDay: TimeInterval = 86_400
let now = Date(timeIntervalSince1970: 1_792_051_200)
let calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
  return calendar
}()

func item(_ name: String, size: Int64 = 1_000) -> Item {
  Item(url: URL(fileURLWithPath: "/Users/me/F/\(name)"), freshness: now, size: size)
}

func report(
  _ id: Int64,
  name: String? = nil,
  _ settings: TemporarySettings = TemporarySettings(),
  items: [Item] = [],
  dueNow: [Item] = [],
  upcoming: [(Item, TimeInterval)] = [],
  wearsTemporary: Bool = true,
  isProtectedRoot: Bool = false,
  readable: Bool = true
) -> FolderReport {
  let folderName = name ?? "Folder\(id)"
  return FolderReport(
    folder: Folder(
      id: id, bookmark: Data(), path: "/Users/me/\(folderName)", settings: settings,
      createdAt: now, lastRunAt: now),
    status: readable
      ? Engine.FolderStatus(
        url: URL(fileURLWithPath: "/Users/me/\(folderName)"), wearsTemporary: wearsTemporary,
        isProtectedRoot: isProtectedRoot, items: items + dueNow + upcoming.map(\.0),
        dueNow: dueNow.map { Removal(item: $0, reasons: [.age]) },
        upcoming: upcoming.map { Upcoming(item: $0.0, date: now.addingTimeInterval($0.1)) })
      : nil)
}
