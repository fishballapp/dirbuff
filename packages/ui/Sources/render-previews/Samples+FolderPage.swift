import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation
import SwiftUI

/// The folder page's made-up folders, as the design reference draws them: Downloads clearing
/// what's older than 14 days, Exports on T7 Shuttle kept under 50 GB, and the rest of the shelf.
extension Samples {
  /// Sun 25 Oct 2026, 13:37 UTC: 23 minutes before the 14:00 clean-up.
  static let pageMoment = now.addingTimeInterval(10 * 86_400 + 5 * 3_600 + 37 * 60)
  /// The real home, so standard folders (`~/Downloads`) draw their own Finder icons.
  static let pageHome = NSHomeDirectory()

  static let pageCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    calendar.locale = Locale(identifier: "en_GB")
    return calendar
  }()

  /// A folder's report as the engine would give it at `pageMoment`.
  static func pageReport(
    id: Int64,
    path: String,
    settings: TemporarySettings,
    items: [Item] = [],
    wearsTemporary: Bool = true,
    turnedOffByLicence: Bool = false,
    problem: FolderProblem? = nil,
    accessLostAt: Date? = nil,
    missingSince: Date? = nil,
    lastRunAt: Date? = nil,
    availableCapacity: Int64 = 120_000_000_000,
    at moment: Date = pageMoment
  ) -> FolderReport {
    let lastRunAt = lastRunAt ?? moment.addingTimeInterval(-37 * 60)
    let folder = Folder(
      id: id, bookmark: Data(), path: path, settings: settings, wearsTemporary: wearsTemporary,
      turnedOffByLicence: turnedOffByLicence,
      accessLostAt: accessLostAt, missingSince: missingSince,
      createdAt: moment.addingTimeInterval(-60 * 86_400), lastRunAt: lastRunAt)
    if let problem { return FolderReport(folder: folder, reading: .failure(problem)) }
    let snapshot = FolderSnapshot(
      wearsTemporary: wearsTemporary, isProtectedRoot: false, items: items)
    let status = Engine.FolderStatus(
      url: URL(fileURLWithPath: path), wearsTemporary: wearsTemporary, isProtectedRoot: false,
      items: items,
      dueNow: plan(
        snapshot, settings: settings,
        conditions: RunConditions(
          now: moment, availableCapacity: availableCapacity,
          totalCapacity: 1_000_000_000_000,
          bootTime: moment.addingTimeInterval(-3 * 86_400), lastRunAt: lastRunAt)),
      upcoming: upcoming(snapshot, settings: settings))
    return FolderReport(folder: folder, reading: .success(status))
  }

  /// `count` files in `path`, each `age` old at `pageMoment`.
  static func pageFiles(
    _ count: Int, in path: String, named name: String, age: TimeInterval, size: Int64
  ) -> [Item] {
    (0..<count).map { index in
      Item(
        url: URL(fileURLWithPath: "\(path)/\(name)-\(index + 1)"),
        freshness: pageMoment.addingTimeInterval(-age), size: size)
    }
  }

  static let downloadsPath = "\(pageHome)/Downloads"
  static let exportsPath = "/Volumes/T7 Shuttle/Exports"

  /// 214 items, 12 of them turning 14 days old at 13:30 tomorrow, so they clear at 14:00.
  static let pageDownloadsItems =
    pageFiles(
      1, in: downloadsPath, named: "keynote-export.zip", age: 13 * 86_400 + 420,
      size: 200_000_000)
    + pageFiles(
      11, in: downloadsPath, named: "invoice.pdf", age: 13 * 86_400 + 420,
      size: 100_000_000)
    + pageFiles(202, in: downloadsPath, named: "photo.heic", age: 3 * 86_400, size: 41_000_000)

  /// Downloads after it changed to 30 days: the oldest turn 30 on Sun 1 Nov.
  static let pageDownloadsLaterItems =
    pageFiles(12, in: downloadsPath, named: "invoice.pdf", age: 23 * 86_400, size: 100_000_000)
    + pageFiles(202, in: downloadsPath, named: "photo.heic", age: 3 * 86_400, size: 41_000_000)

  static let pageExportsItems = pageFiles(
    1_204, in: exportsPath, named: "frame.exr", age: 2 * 86_400, size: 39_036_545)

  /// The shelf around the page, with `downloads` and `exports` swapped in for each state.
  static func pageReports(
    downloads: FolderReport? = nil, exports: FolderReport? = nil, extra: [FolderReport] = []
  ) -> [FolderReport] {
    [
      downloads
        ?? pageReport(
          id: 1, path: downloadsPath, settings: TemporarySettings(maxAgeDays: 14),
          items: pageDownloadsItems),
      pageReport(
        id: 2, path: "\(pageHome)/Projects", settings: TemporarySettings(maxAgeDays: 30),
        problem: .noAccess, accessLostAt: pageMoment.addingTimeInterval(-3 * 86_400 - 120)),
      exports
        ?? pageReport(
          id: 3, path: exportsPath,
          settings: TemporarySettings(rule: .size, sizeLimit: 50_000_000_000, disposal: .delete),
          items: pageExportsItems),
      pageReport(
        id: 4, path: "\(pageHome)/Screenshots", settings: TemporarySettings(rule: .emptyOnRestart),
        items: pageFiles(
          38, in: "\(pageHome)/Screenshots", named: "shot.png", age: 86_400, size: 2_500_000)),
    ] + extra
  }

  /// The site's folders, as `site` reads them.
  static var siteReports: [FolderReport] {
    [
      pageReport(
        id: 1, path: "/Users/sample/Downloads", settings: siteDownloadsSettings,
        items: siteDownloadsItems, lastRunAt: now, at: shownAt)
    ] + reports.dropFirst()
  }

  /// Draws a pushed folder page from `state` and its `reports`, as the app's `MainContainerView`
  /// does.
  static func folderPageDestination(
    _ state: MainState, reports: [FolderReport], now: Date, home: String = NSHomeDirectory()
  ) -> (MainRoute) -> AnyView {
    { route in
      guard case .folder(let id) = route,
        let page = FolderPageState(
          folderID: id, reports: reports, shelf: state, now: now, calendar: pageCalendar,
          binName: binName, home: home)
      else { return AnyView(EmptyView()) }
      return AnyView(FolderPage(state: page, binName: binName))
    }
  }

  static func pageState(
    _ id: Int64,
    reports: [FolderReport],
    licence: Licence = .trial(daysLeft: 9),
    working: Set<Int64> = [],
    progress: Engine.RunProgress? = nil
  ) -> FolderPageState {
    let shelf = MainState(
      reports: reports, licence: licence, working: working, progress: progress, now: pageMoment,
      calendar: pageCalendar, binName: binName, home: pageHome, startupVolumeName: "Macintosh HD")
    guard
      let state = FolderPageState(
        folderID: id, reports: reports, shelf: shelf, progress: progress, now: pageMoment,
        calendar: pageCalendar, binName: binName, home: pageHome)
    else { fail("no sample folder \(id)") }
    return state
  }
}
