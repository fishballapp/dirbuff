import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation
import SwiftUI

/// The main window's shelf and tile states: the six-folder fixture at 1240 × 800, each tile state,
/// a narrow two-column window, the filtered states, the empty shelf, and a pushed folder page.
@MainActor
func mainWindowPreviews() -> [Preview] {
  let fullSize = CGSize(width: 1240, height: 800)
  let narrowSize = CGSize(width: 880, height: 720)
  return [
    (
      "main-overview",
      AnyView(
        MainView(
          state: Samples.shelf(),
          selection: .constant(.shelf),
          binName: Samples.binName
        )),
      fullSize
    ),
    (
      "main-shelf-working",
      AnyView(
        MainView(
          state: Samples.shelf(working: [1]),
          selection: .constant(.shelf),
          binName: Samples.binName
        )),
      fullSize
    ),
    (
      "main-shelf-taken-off",
      AnyView(
        MainView(
          state: Samples.shelfTakenOff,
          selection: .constant(.shelf),
          binName: Samples.binName
        )),
      CGSize(width: 1088, height: 420)
    ),
    (
      "main-overview-trial-ended",
      AnyView(
        MainView(
          state: Samples.shelfPaused(licence: .trialEnded),
          selection: .constant(.shelf),
          binName: Samples.binName
        )),
      fullSize
    ),
    (
      "main-overview-licence-ended",
      AnyView(
        MainView(
          state: Samples.shelfPaused(
            licence: .ended(paidThrough: Samples.shelfMoment.addingTimeInterval(-30 * 86_400))),
          selection: .constant(.shelf),
          binName: Samples.binName
        )),
      fullSize
    ),
    (
      "main-shelf-unplugged",
      AnyView(
        MainView(
          state: Samples.shelfUnplugged,
          selection: .constant(.shelf),
          binName: Samples.binName
        )),
      fullSize
    ),
    (
      "main-shelf-narrow",
      AnyView(
        MainView(
          state: Samples.shelf(),
          selection: .constant(.shelf),
          binName: Samples.binName
        )),
      narrowSize
    ),
    (
      "main-shelf-filtered",
      AnyView(
        MainView(
          state: Samples.shelf(),
          selection: .constant(.shelf),
          binName: Samples.binName,
          initialSearchQuery: "Screen"
        )),
      fullSize
    ),
    (
      "main-shelf-filtered-empty",
      AnyView(
        MainView(
          state: Samples.shelf(),
          selection: .constant(.shelf),
          binName: Samples.binName,
          initialSearchQuery: "Invoices"
        )),
      fullSize
    ),
    (
      "main-shelf-empty",
      AnyView(
        MainView(
          state: Samples.shelfEmpty,
          selection: .constant(.shelf),
          binName: Samples.binName
        )),
      fullSize
    ),
    (
      "main-folder-on",
      AnyView(
        MainView(
          state: Samples.shelf(),
          selection: .constant(.folder(1)),
          binName: Samples.binName
        )),
      fullSize
    ),
  ]
}

extension Samples {
  /// Real home directory so existing standard folders (`~/Downloads`) draw their real Finder icons
  /// while `MainState` still formats locations as `~/…`.
  fileprivate static let shelfHome = NSHomeDirectory()
  /// Sun 25 Oct 2026, 13:37 UTC — 23 minutes before the 14:00 clean-up.
  fileprivate static let shelfMoment = now.addingTimeInterval(10 * 86_400 + 5 * 3_600 + 37 * 60)

  fileprivate static let shelfCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    calendar.locale = Locale(identifier: "en_GB")
    return calendar
  }()

  private static func shelfFile(
    in folderPath: String,
    name: String,
    daysOld: Double,
    size: Int64
  ) -> Item {
    Item(
      url: URL(fileURLWithPath: "\(folderPath)/\(name)"),
      freshness: shelfMoment.addingTimeInterval(-daysOld * 86_400),
      size: size
    )
  }

  private static func shelfReport(
    id: Int64,
    path: String,
    settings: TemporarySettings,
    items: [Item] = [],
    wearsTemporary: Bool = true,
    takenOffAt: Date? = nil,
    turnedOffByLicence: Bool = false,
    problem: FolderProblem? = nil,
    accessLostAt: Date? = nil
  ) -> FolderReport {
    let folder = Folder(
      id: id,
      bookmark: Data(),
      path: path,
      settings: settings,
      wearsTemporary: wearsTemporary,
      takenOffAt: takenOffAt,
      turnedOffByLicence: turnedOffByLicence,
      accessLostAt: accessLostAt,
      createdAt: shelfMoment.addingTimeInterval(-60 * 86_400),
      lastRunAt: shelfMoment.addingTimeInterval(-37 * 60)
    )
    if let problem {
      return FolderReport(folder: folder, reading: .failure(problem))
    }
    let snapshot = FolderSnapshot(
      wearsTemporary: wearsTemporary,
      isProtectedRoot: false,
      items: items
    )
    let status = Engine.FolderStatus(
      url: URL(fileURLWithPath: path),
      wearsTemporary: wearsTemporary,
      isProtectedRoot: false,
      items: items,
      dueNow: plan(
        snapshot,
        settings: settings,
        conditions: RunConditions(
          now: shelfMoment,
          availableCapacity: 120_000_000_000,
          totalCapacity: 500_000_000_000,
          bootTime: shelfMoment.addingTimeInterval(-3 * 86_400),
          lastRunAt: shelfMoment.addingTimeInterval(-37 * 60)
        )
      ),
      upcoming: upcoming(snapshot, settings: settings)
    )
    return FolderReport(folder: folder, reading: .success(status))
  }

  private static var shelfDownloadsItems: [Item] {
    let path = "\(shelfHome)/Downloads"
    return (0..<12).map { index in
      shelfFile(
        in: path,
        name: "download-\(index).zip",
        daysOld: 13.3,
        size: index == 0 ? 200_000_000 : 100_000_000
      )
    }
  }

  private static var shelfScreenshotsItems: [Item] {
    let path = "\(shelfHome)/Screenshots"
    return (0..<38).map { index in
      shelfFile(in: path, name: "shot-\(index).png", daysOld: 1, size: 2_500_000)
    }
  }

  fileprivate static func shelfReports(paused: Bool = false) -> [FolderReport] {
    [
      shelfReport(
        id: 1,
        path: "\(shelfHome)/Downloads",
        settings: TemporarySettings(maxAgeDays: 14),
        items: shelfDownloadsItems,
        wearsTemporary: !paused,
        turnedOffByLicence: paused
      ),
      shelfReport(
        id: 2,
        path: "\(shelfHome)/Projects",
        settings: TemporarySettings(maxAgeDays: 30),
        wearsTemporary: !paused,
        turnedOffByLicence: paused,
        problem: .noAccess,
        accessLostAt: shelfMoment.addingTimeInterval(-3 * 86_400 - 120)
      ),
      shelfReport(
        id: 3,
        path: "/Volumes/T7 Shuttle/Exports",
        settings: TemporarySettings(rule: .size, sizeLimit: 50_000_000_000),
        items: [
          shelfFile(
            in: "/Volumes/T7 Shuttle/Exports",
            name: "master.mov",
            daysOld: 2,
            size: 47_000_000_000
          )
        ],
        wearsTemporary: !paused,
        turnedOffByLicence: paused
      ),
      shelfReport(
        id: 4,
        path: "\(shelfHome)/Recordings",
        settings: TemporarySettings(maxAgeDays: 60),
        items: [
          shelfFile(
            in: "\(shelfHome)/Recordings", name: "call.m4a", daysOld: 55, size: 38_000_000
          )
        ],
        wearsTemporary: !paused,
        turnedOffByLicence: paused
      ),
      shelfReport(
        id: 5,
        path: "\(shelfHome)/Scratch",
        settings: TemporarySettings(rule: .size, sizeLimit: 10_000_000_000, disposal: .delete),
        items: [
          shelfFile(
            in: "\(shelfHome)/Scratch", name: "cache.bin", daysOld: 2, size: 8_100_000_000
          )
        ],
        wearsTemporary: !paused,
        turnedOffByLicence: paused
      ),
      shelfReport(
        id: 6,
        path: "\(shelfHome)/Screenshots",
        settings: TemporarySettings(rule: .emptyOnRestart),
        items: shelfScreenshotsItems,
        wearsTemporary: !paused,
        turnedOffByLicence: paused
      ),
    ]
  }

  fileprivate static func shelf(
    licence: Licence = .trial(daysLeft: 9),
    working: Set<Int64> = []
  ) -> MainState {
    MainState(
      reports: shelfReports(),
      licence: licence,
      working: working,
      now: shelfMoment,
      calendar: shelfCalendar,
      binName: binName,
      home: shelfHome,
      startupVolumeName: "Macintosh HD"
    )
  }

  fileprivate static var shelfTakenOff: MainState {
    MainState(
      reports: [
        shelfReports()[0],
        shelfReport(
          id: 6,
          path: "\(shelfHome)/Screenshots",
          settings: TemporarySettings(rule: .emptyOnRestart),
          items: shelfScreenshotsItems,
          wearsTemporary: false,
          takenOffAt: shelfMoment
        ),
      ],
      licence: .licensed,
      now: shelfMoment,
      calendar: shelfCalendar,
      binName: binName,
      home: shelfHome,
      startupVolumeName: "Macintosh HD"
    )
  }

  fileprivate static func shelfPaused(licence: Licence) -> MainState {
    MainState(
      reports: shelfReports(paused: true),
      licence: licence,
      now: shelfMoment,
      calendar: shelfCalendar,
      binName: binName,
      home: shelfHome,
      startupVolumeName: "Macintosh HD"
    )
  }

  fileprivate static var shelfUnplugged: MainState {
    var reports = shelfReports()
    reports[2] = shelfReport(
      id: 3,
      path: "/Volumes/T7 Shuttle/Exports",
      settings: TemporarySettings(rule: .size, sizeLimit: 50_000_000_000),
      problem: .unreachable
    )
    return MainState(
      reports: reports,
      licence: .trial(daysLeft: 9),
      now: shelfMoment,
      calendar: shelfCalendar,
      binName: binName,
      home: shelfHome,
      startupVolumeName: "Macintosh HD"
    )
  }

  fileprivate static var shelfEmpty: MainState {
    MainState(
      reports: [],
      licence: .trial(daysLeft: 9),
      now: shelfMoment,
      calendar: shelfCalendar,
      binName: binName,
      home: shelfHome,
      startupVolumeName: "Macintosh HD"
    )
  }
}
