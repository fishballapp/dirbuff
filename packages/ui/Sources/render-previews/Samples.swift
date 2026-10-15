import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation

/// Made-up folders, files and runs for the preview renders. Not anyone's real data.
enum Samples {
  /// The Bin's name in the site's and the app's language (UK English), so the previews don't
  /// read the Mac they're drawn on.
  static let binName = "Bin"
  static let now = Date(timeIntervalSince1970: 1_792_051_200)  // Tue 14 Oct 2026, 08:00 UTC
  /// The windows are drawn between clean-ups, so their countdowns read "In 23 min".
  static let shownAt = now.addingTimeInterval(37 * 60)
  private static let day: TimeInterval = 86_400

  private static func item(_ folder: String, _ name: String, daysOld: Double, size: Int64) -> Item {
    Item(
      url: URL(fileURLWithPath: "/Users/sample/\(folder)/\(name)"),
      freshness: now.addingTimeInterval(-daysOld * day),
      size: size)
  }

  private static func folder(_ id: Int64, _ name: String, _ settings: TemporarySettings)
    -> Folder
  {
    Folder(
      id: id, bookmark: Data(), path: "/Users/sample/\(name)", settings: settings,
      createdAt: now.addingTimeInterval(-90 * day), lastRunAt: now)
  }

  /// A status as the engine would report it for these items under `settings`.
  private static func status(
    _ name: String, _ items: [Item], _ settings: TemporarySettings, isTagged: Bool = true
  ) -> Engine.FolderStatus {
    let snapshot = FolderSnapshot(isTagged: isTagged, isProtectedRoot: false, items: items)
    return Engine.FolderStatus(
      url: URL(fileURLWithPath: "/Users/sample/\(name)"), isTagged: isTagged,
      isProtectedRoot: false, items: items,
      dueNow: plan(
        snapshot, settings: settings,
        conditions: RunConditions(
          now: now, availableCapacity: 120_000_000_000, totalCapacity: 500_000_000_000,
          bootTime: now.addingTimeInterval(-3 * day), lastRunAt: now)),
      upcoming: upcoming(snapshot, settings: settings))
  }

  static let downloadsSettings = TemporarySettings(maxAgeDays: 30)
  static let downloadsItems = [
    item("Downloads", "invoice_2026_09.pdf", daysOld: 41, size: 220_000),
    item("Downloads", "Screenshot 2026-09-01 at 10.12.png", daysOld: 38, size: 2_400_000),
    item("Downloads", "zoom_installer.pkg", daysOld: 33, size: 54_000_000),
    item("Downloads", "archive-dump.tar.gz", daysOld: 31, size: 1_200_000_000),
    item("Downloads", "meeting-notes.docx", daysOld: 29.9, size: 640_000),
    item("Downloads", "design-brief-v1.pdf", daysOld: 29.2, size: 3_100_000),
    item("Downloads", "client-assets.zip", daysOld: 29.1, size: 410_000_000),
    item("Downloads", "boarding-pass.pdf", daysOld: 2, size: 90_000),
  ]
  static let scratchSettings = TemporarySettings(
    maxAgeDays: nil, sizeLimit: 10_000_000_000, emptyOnRestart: true, disposal: .delete)
  static let scratchItems = [
    item("Scratch", "build-artifacts", daysOld: 4, size: 6_200_000_000),
    item("Scratch", "render-cache.tmp", daysOld: 1, size: 1_900_000_000),
  ]
  static let recordingsSettings = TemporarySettings(maxAgeDays: 60)
  static let recordingsItems = [
    item("Recordings", "standup-2026-08-20.m4a", daysOld: 55, size: 38_000_000)
  ]
  static let archiveSettings = TemporarySettings(maxAgeDays: 90)
  static let archiveItems = [
    item("Archive", "old-project.zip", daysOld: 100, size: 50_000_000)
  ]

  static let reports: [FolderReport] = [
    FolderReport(
      folder: folder(1, "Downloads", downloadsSettings),
      status: status("Downloads", downloadsItems, downloadsSettings)),
    FolderReport(
      folder: folder(2, "Scratch", scratchSettings),
      status: status("Scratch", scratchItems, scratchSettings)),
    FolderReport(
      folder: folder(3, "Recordings", recordingsSettings),
      status: status("Recordings", recordingsItems, recordingsSettings)),
    FolderReport(
      folder: folder(4, "Archive", archiveSettings),
      status: status("Archive", archiveItems, archiveSettings, isTagged: false)),
  ]

  static let journal: [JournalEntry] = [
    JournalEntry(
      id: 1, folderID: 1, disposal: .bin, name: "invoice_2026_08.pdf", size: 180_000,
      reasons: [.age], performedAt: now.addingTimeInterval(-28_800)),
    JournalEntry(
      id: 2, folderID: 1, disposal: .bin, name: "mockup-export.png", size: 4_200_000,
      reasons: [.age], performedAt: now.addingTimeInterval(-28_800)),
    JournalEntry(
      id: 3, folderID: 1, disposal: .bin, name: "setup.dmg", size: 120_000_000,
      reasons: [.age], performedAt: now.addingTimeInterval(-28_800)),
    JournalEntry(
      id: 4, folderID: 2, disposal: .delete, name: "target-build", size: 2_400_000_000,
      reasons: [.size], performedAt: now.addingTimeInterval(-43_200)),
    JournalEntry(
      id: 5, folderID: 2, disposal: .delete, name: "test-run.log", size: 12_000_000,
      reasons: [.size], performedAt: now.addingTimeInterval(-43_200)),
  ]

  private static let calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
  }()

  static let busy = MenuBarState(
    reports: reports, journal: journal, freeSpace: 124_500_000_000, isFinderExtensionOff: false,
    licence: .licensed, now: shownAt, calendar: calendar, binName: binName)

  /// The minute before a clean-up, when the countdown is to the second.
  static let lastMinute = MenuBarState(
    reports: reports, journal: journal, freeSpace: 124_500_000_000, isFinderExtensionOff: false,
    licence: .licensed, now: now.addingTimeInterval(3_558), calendar: calendar, binName: binName)

  static let quiet = MenuBarState(
    reports: [
      FolderReport(
        folder: folder(1, "Downloads", downloadsSettings),
        status: status("Downloads", [], downloadsSettings)),
      FolderReport(
        folder: folder(2, "Scratch", scratchSettings),
        status: status("Scratch", [], scratchSettings)),
    ],
    journal: [], freeSpace: 280_000_000_000, isFinderExtensionOff: false,
    licence: .licensed, now: shownAt, calendar: calendar, binName: binName)

  static let noFolders = MenuBarState(
    reports: [], journal: [], freeSpace: 280_000_000_000, isFinderExtensionOff: false,
    licence: .licensed, now: shownAt, calendar: calendar, binName: binName)

  static let extensionOff = MenuBarState(
    reports: reports, journal: journal, freeSpace: 124_500_000_000, isFinderExtensionOff: true,
    licence: .licensed, now: shownAt, calendar: calendar, binName: binName)

  /// The last day Polar confirmed the key, in the sample's clock.
  static let paidThrough = now.addingTimeInterval(-20 * 86_400)
  /// The licence ended, and this version came out while it held.
  static let kept = Licence.kept(paidThrough: paidThrough)
  /// The licence ended, and this version came out after.
  static let ended = Licence.ended(paidThrough: paidThrough)

  static func menuBar(_ licence: Licence) -> MenuBarState {
    MenuBarState(
      reports: reports, journal: journal, freeSpace: 124_500_000_000, isFinderExtensionOff: false,
      licence: licence, now: shownAt, calendar: calendar, binName: binName)
  }

  /// The site's main window: one Temporary Downloads folder with every rule on, and three items
  /// due in the coming week.
  static let siteDownloadsSettings = TemporarySettings(
    maxAgeDays: 90, sizeLimit: 10_000_000_000, automatic: false, emptyOnRestart: true,
    disposal: .bin)
  static let siteDownloadsItems = [
    item("Downloads", "Xcode_Helper.dmg", daysOld: 89.2, size: 7_300_000),
    item("Downloads", "invoice-2026-07.pdf", daysOld: 87.4, size: 2_100_000),
    item("Downloads", "Zoom_installer.pkg", daysOld: 85.6, size: 6_300_000),
    item("Downloads", "design-brief-v1.pdf", daysOld: 12, size: 3_100_000),
    item("Downloads", "boarding-pass.pdf", daysOld: 2, size: 90_000),
  ]

  /// The site's sidebar: Downloads with the site's rules, then the other sample folders.
  static let site = MainState(
    reports: [
      FolderReport(
        folder: folder(1, "Downloads", siteDownloadsSettings),
        status: status("Downloads", siteDownloadsItems, siteDownloadsSettings))
    ] + reports.dropFirst(),
    journal: [], freeSpace: 124_500_000_000, isFinderExtensionOff: false,
    licence: .licensed, now: shownAt, calendar: calendar, binName: binName)

  static func settings(_ licence: Licence, shouldGetDevBuilds: Bool = false) -> SettingsState {
    SettingsState(
      openAtLogin: true, openAtLoginRequiresApproval: false, showInMenuBar: true,
      shouldGetDevBuilds: shouldGetDevBuilds, version: "0.1.3 (2126)", licence: licence,
      licenceKey: "DIRBUFF-9AD0419A-553D-4FB1-A8C2-F40AE9E63D8D")
  }

  static let setup = SetupState(
    isExtensionEnabled: false, isOpenAtLogin: true, isOpenAtLoginRequiresApproval: false,
    isNotificationsEnabled: false)

  static let main = MainState(
    reports: reports, journal: journal, freeSpace: 124_500_000_000, isFinderExtensionOff: false,
    licence: .licensed, now: shownAt, calendar: calendar, binName: binName)

  static func main(_ licence: Licence) -> MainState {
    MainState(
      reports: reports, journal: journal, freeSpace: 124_500_000_000, isFinderExtensionOff: false,
      licence: licence, now: shownAt, calendar: calendar, binName: binName)
  }
}
