import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation

/// Made-up folders and files for the preview renders. Not anyone's real data.
enum Samples {
  /// The Bin's name in the site's and the app's language (UK English), so the previews don't
  /// read the Mac they're drawn on.
  static let binName = "Bin"
  /// The made-up home every sample folder sits in. Previews outside these files name it rather
  /// than spell a path, so the public tree's leak check knows it as a fixture.
  static let home = "/Users/sample"
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

  private static func folder(_ id: Int64, _ name: String) -> Folder {
    Folder(
      id: id, bookmark: Data(), path: "/Users/sample/\(name)",
      createdAt: now.addingTimeInterval(-90 * day))
  }

  /// A status as the engine would report it for these items under `settings`.
  private static func status(
    _ name: String, _ items: [Item], _ settings: TemporarySettings, wearsTemporary: Bool = true
  ) -> TemporaryStatus {
    let snapshot = FolderSnapshot(
      wearsTemporary: wearsTemporary, isProtectedRoot: false, items: items)
    return TemporaryStatus(
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

  static let reports: [FolderReport] = [
    .sample(
      folder(1, "Downloads"), settings: downloadsSettings, lastRunAt: now,
      reading: .success(status("Downloads", downloadsItems, downloadsSettings))),
    .sample(
      folder(2, "Scratch"), settings: scratchSettings, lastRunAt: now,
      reading: .success(status("Scratch", scratchItems, scratchSettings))),
    .sample(
      folder(3, "Recordings"), settings: recordingsSettings, lastRunAt: now,
      reading: .success(status("Recordings", recordingsItems, recordingsSettings))),
    // It wears no buff, so it's found but never read.
    .sample(folder(4, "Archive"), lastRunAt: now, reading: .success(nil)),
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
  /// and three items due in the coming week (`site`, in `Samples+FolderPage`).
  static let siteDownloadsSettings = TemporarySettings(maxAgeDays: 90)
  static let siteDownloadsItems = [
    item("Downloads", "Xcode_Helper.dmg", daysOld: 89.2, size: 7_300_000),
    item("Downloads", "invoice-2026-07.pdf", daysOld: 87.4, size: 2_100_000),
    item("Downloads", "Zoom_installer.pkg", daysOld: 85.6, size: 6_300_000),
    item("Downloads", "design-brief-v1.pdf", daysOld: 12, size: 3_100_000),
    item("Downloads", "boarding-pass.pdf", daysOld: 2, size: 90_000),
  ]
}

extension FolderReport {
  /// A report as the app builds it, from what finding and reading the folder gave as one result.
  /// The folder wears Temporary while `settings` is given, paused by the licence if `isPaused`.
  static func sample(
    _ folder: Folder,
    settings: TemporarySettings? = nil,
    isPaused: Bool = false,
    lastRunAt: Date,
    reading: Result<TemporaryStatus?, FolderProblem>
  ) -> FolderReport {
    let wear = settings.map {
      Wear(
        folderID: folder.id ?? 0, settings: $0, isPausedByLicence: isPaused, lastRunAt: lastRunAt)
    }
    switch reading {
    case .failure(let problem):
      return FolderReport(
        folder: folder, location: .failure(problem),
        buffs: wear.map { [.temporary($0, nil)] } ?? [])
    case .success(let status):
      return FolderReport(
        folder: folder, location: .success(URL(fileURLWithPath: folder.path)),
        buffs: wear.map { [.temporary($0, status.map { .success($0) })] } ?? [])
    }
  }
}
