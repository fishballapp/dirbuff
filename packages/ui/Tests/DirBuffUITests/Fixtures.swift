import DirBuffCore
import DirBuffKit
import Foundation

@testable import DirBuffUI

/// Reports and items both suites build their states from.
let oneDay: TimeInterval = 86_400
/// A made-up home folder that every fixture folder sits in.
let home = "/Users/me"
let now = Date(timeIntervalSince1970: 1_792_051_200)
let calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
  return calendar
}()

func item(_ name: String, size: Int64 = 1_000) -> Item {
  Item(url: URL(fileURLWithPath: "\(home)/F/\(name)"), freshness: now, size: size)
}

func report(
  _ id: Int64,
  name: String? = nil,
  path: String? = nil,
  _ settings: TemporarySettings = TemporarySettings(),
  items: [Item] = [],
  dueNow: [Item] = [],
  upcoming: [(Item, TimeInterval)] = [],
  wearsTemporary: Bool = true,
  isProtectedRoot: Bool = false,
  problem: FolderProblem? = nil,
  takenOffAt: Date? = nil,
  turnedOffByLicence: Bool = false,
  accessLostAt: Date? = nil
) -> FolderReport {
  let path = path ?? "\(home)/\(name ?? "Folder\(id)")"
  return FolderReport(
    folder: Folder(
      id: id, bookmark: Data(), path: path, settings: settings,
      wearsTemporary: wearsTemporary, takenOffAt: takenOffAt,
      turnedOffByLicence: turnedOffByLicence, accessLostAt: accessLostAt, createdAt: now,
      lastRunAt: now),
    reading: problem.map { .failure($0) }
      ?? .success(
        Engine.FolderStatus(
          url: URL(fileURLWithPath: path), wearsTemporary: wearsTemporary,
          isProtectedRoot: isProtectedRoot, items: items + dueNow + upcoming.map(\.0),
          dueNow: dueNow.map { Removal(item: $0, rule: settings.rule) },
          upcoming: upcoming.map { Upcoming(item: $0.0, date: now.addingTimeInterval($0.1)) })))
}
