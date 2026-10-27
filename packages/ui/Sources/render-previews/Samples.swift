import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation

/// Made-up folders and files for the preview renders. Not anyone's real data.
enum Samples {
  /// The Bin's name in the site's and the app's language (UK English), so the previews don't
  /// read the Mac they're drawn on.
  static let binName = "Bin"
  static let now = Date(timeIntervalSince1970: 1_792_051_200)  // Thu 15 Oct 2026, 08:00 UTC
  /// The windows are drawn between clean-ups, so their countdowns read "In 23 min".
  static let shownAt = now.addingTimeInterval(37 * 60)
  private static let day: TimeInterval = 86_400

  private static func item(_ folder: String, _ name: String, daysOld: Double, size: Int64) -> Item {
    Item(
      url: URL(fileURLWithPath: "/Users/sample/\(folder)/\(name)"),
      freshness: now.addingTimeInterval(-daysOld * day),
      size: size)
  }

  private static func folder(
    _ id: Int64, _ name: String, _ settings: TemporarySettings, wearsTemporary: Bool = true
  ) -> Folder {
    Folder(
      id: id, bookmark: Data(), path: "/Users/sample/\(name)", settings: settings,
      wearsTemporary: wearsTemporary, createdAt: now.addingTimeInterval(-90 * day), lastRunAt: now)
  }

  /// A status as the engine would report it for these items under `settings`.
  private static func status(
    _ name: String, _ items: [Item], _ settings: TemporarySettings, wearsTemporary: Bool = true
  ) -> Engine.FolderStatus {
    let snapshot = FolderSnapshot(
      wearsTemporary: wearsTemporary, isProtectedRoot: false, items: items)
    return Engine.FolderStatus(
      url: URL(fileURLWithPath: "/Users/sample/\(name)"), wearsTemporary: wearsTemporary,
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
    rule: .size, sizeLimit: 10_000_000_000, disposal: .delete)
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
      reading: .success(status("Downloads", downloadsItems, downloadsSettings))),
    FolderReport(
      folder: folder(2, "Scratch", scratchSettings),
      reading: .success(status("Scratch", scratchItems, scratchSettings))),
    FolderReport(
      folder: folder(3, "Recordings", recordingsSettings),
      reading: .success(status("Recordings", recordingsItems, recordingsSettings))),
    FolderReport(
      folder: folder(4, "Archive", archiveSettings, wearsTemporary: false),
      reading: .success(status("Archive", archiveItems, archiveSettings, wearsTemporary: false))),
  ]

  private static let calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    return calendar
  }()

  /// The last day Polar confirmed the key, in the sample's clock.
  static let paidThrough = now.addingTimeInterval(-20 * 86_400)
  /// The licence ended, and this version came out while it held.
  static let kept = Licence.kept(paidThrough: paidThrough)
  /// The licence ended, and this version came out after.
  static let ended = Licence.ended(paidThrough: paidThrough)

  /// The site's main window: one Temporary Downloads folder clearing what's older than 90 days,
  /// and three items due in the coming week.
  static let siteDownloadsSettings = TemporarySettings(maxAgeDays: 90)
  static let siteDownloadsItems = [
    item("Downloads", "Xcode_Helper.dmg", daysOld: 89.2, size: 7_300_000),
    item("Downloads", "invoice-2026-07.pdf", daysOld: 87.4, size: 2_100_000),
    item("Downloads", "Zoom_installer.pkg", daysOld: 85.6, size: 6_300_000),
    item("Downloads", "design-brief-v1.pdf", daysOld: 12, size: 3_100_000),
    item("Downloads", "boarding-pass.pdf", daysOld: 2, size: 90_000),
  ]

  /// The site's main window: Downloads with the site's rules, then the other sample folders.
  static let site = MainState(
    reports: [
      FolderReport(
        folder: folder(1, "Downloads", siteDownloadsSettings),
        reading: .success(status("Downloads", siteDownloadsItems, siteDownloadsSettings)))
    ] + reports.dropFirst(),
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
}
