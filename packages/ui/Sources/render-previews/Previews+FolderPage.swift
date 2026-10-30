import DirBuffCore
import DirBuffKit
import DirBuffUI
import SwiftUI

/// A folder's page, in each state of its buffs, in the 1240 pt window with its sidebar row
/// selected; and a folder that wears nothing, with its buffs to put on.
@MainActor
func folderPagePreviews() -> [Preview] {
  let full = CGSize(width: 1240, height: 800)
  let short = CGSize(width: 1240, height: 520)
  let reports = Samples.pageReports()
  let downloads = Samples.pageReport(
    id: 1, path: Samples.downloadsPath, settings: TemporarySettings(maxAgeDays: 30),
    items: Samples.pageDownloadsLaterItems)
  let missing = Samples.pageReport(
    id: 5, path: "\(Samples.pageHome)/Thesis", settings: TemporarySettings(maxAgeDays: 14),
    problem: .missing, missingSince: Samples.pageMoment.addingTimeInterval(-3 * 86_400 - 3_420))

  return [
    ("folder-page-age", page(1, reports), full),
    ("folder-page-size", page(3, reports), full),
    (
      "folder-page-toast",
      page(
        1, Samples.pageReports(downloads: downloads),
        toast: SettingsToast(
          change: settingChange(
            from: TemporarySettings(maxAgeDays: 14), to: TemporarySettings(maxAgeDays: 30),
            binName: Samples.binName),
          previous: TemporarySettings(maxAgeDays: 14))),
      short
    ),
    ("folder-page-restart", page(4, reports), short),
    (
      "folder-page-disk",
      page(
        1,
        Samples.pageReports(
          downloads: Samples.pageReport(
            id: 1, path: Samples.downloadsPath, settings: TemporarySettings(rule: .automatic),
            items: Samples.pageDownloadsItems, availableCapacity: 60_000_000_000))),
      short
    ),
    (
      "folder-page-working",
      page(
        1, reports, working: [1],
        progress: Engine.RunProgress(
          folderID: 1, itemsDone: 3, itemsTotal: 12, bytesDone: 400_000_000,
          bytesTotal: 1_300_000_000, current: "invoice.pdf-4")),
      short
    ),
    ("folder-page-needs-access", page(2, reports), short),
    ("folder-page-missing", page(5, Samples.pageReports(extra: [missing])), short),
    ("folder-page-paused", page(1, pausedReports(), licence: .trialEnded), short),
    (
      "folder-page-unplugged",
      page(
        3,
        Samples.pageReports(
          exports: Samples.pageReport(
            id: 3, path: Samples.exportsPath,
            settings: TemporarySettings(rule: .size, sizeLimit: 50_000_000_000, disposal: .delete),
            problem: .unreachable))),
      short
    ),
    (
      "folder-page-no-buffs",
      page(
        6,
        Samples.pageReports(extra: [
          Samples.pageReport(
            id: 6, path: "\(Samples.pageHome)/Music", settings: TemporarySettings(),
            wearsTemporary: false)
        ])),
      CGSize(width: 1240, height: 360)
    ),
    ("folder-page-narrow", page(3, reports), CGSize(width: 860, height: 800)),
  ]
}

/// The page for folder `id`, its sidebar row selected, as the app shows it.
@MainActor
private func page(
  _ id: Int64,
  _ reports: [FolderReport],
  licence: Licence = .trial(daysLeft: 9),
  working: Set<Int64> = [],
  progress: Engine.RunProgress? = nil,
  toast: SettingsToast? = nil
) -> AnyView {
  let state = Samples.pageState(
    id, reports: reports, licence: licence, working: working, progress: progress)
  let shelf = MainState(
    reports: reports, licence: licence, working: working, progress: progress,
    now: Samples.pageMoment, calendar: Samples.pageCalendar, binName: Samples.binName,
    home: Samples.pageHome, startupVolumeName: "Macintosh HD")
  return AnyView(
    MainView(
      state: shelf,
      navigation: .constant(MainNavigation(.folder(id))),
      folderPage: { _ in
        AnyView(FolderPage(state: state, binName: Samples.binName, toast: toast))
      }))
}

/// Every folder paused at the trial's end.
private func pausedReports() -> [FolderReport] {
  Samples.pageReports().map { report in
    Samples.pageReport(
      id: report.folder.id ?? 0, path: report.folder.path, settings: report.folder.settings,
      items: report.status?.items ?? [], wearsTemporary: false, turnedOffByLicence: true)
  }
}
