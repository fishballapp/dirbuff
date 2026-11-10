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
  isPausedByLicence: Bool = false,
  accessLostAt: Date? = nil,
  missingSince: Date? = nil
) -> FolderReport {
  let path = path ?? "\(home)/\(name ?? "Folder\(id)")"
  let folder = Folder(
    id: id, bookmark: Data(), path: path, accessLostAt: accessLostAt, missingSince: missingSince,
    createdAt: now)
  let wear =
    wearsTemporary || isPausedByLicence
    ? Wear(folderID: id, settings: settings, isPausedByLicence: isPausedByLicence, lastRunAt: now)
    : nil
  if let problem {
    return FolderReport(
      folder: folder, location: .failure(problem),
      buffs: wear.map { [.temporary($0, nil)] } ?? [])
  }
  // A folder that wears no buff is found but never read.
  let status = TemporaryStatus(
    url: URL(fileURLWithPath: path), wearsTemporary: wearsTemporary,
    isProtectedRoot: isProtectedRoot, items: items + dueNow + upcoming.map(\.0),
    dueNow: dueNow.map { Removal(item: $0, rule: settings.rule) },
    upcoming: upcoming.map { Upcoming(item: $0.0, date: now.addingTimeInterval($0.1)) })
  return FolderReport(
    folder: folder, location: .success(URL(fileURLWithPath: path)),
    buffs: wear.map { [.temporary($0, .success(status))] } ?? [])
}
