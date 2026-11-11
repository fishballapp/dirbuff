import DirBuffCore
import DirBuffKit
import DirBuffUI
import SwiftUI

/// Backup in every state it can be in, on every surface that shows a buff: the shelf's tiles and
/// the sidebar's symbols (windows, each with a folder per state), a folder's page, the popover and
/// Finder's menu. What only a wearable Backup has is in `Previews+BackupLive`.
@MainActor
func backupPreviews() -> [Preview] {
  let full = CGSize(width: 1240, height: 800)
  let short = CGSize(width: 1240, height: 540)
  let medium = CGSize(width: 1240, height: 700)
  let working = Samples.backupProgress(folder: 3)

  /// The window on `reports`, with a folder's page open if `page` is given.
  func window(
    _ reports: [FolderReport], page: Int64? = nil, licence: Licence = .licensed,
    backingUp: Set<Int64> = [], progress: RunProgress? = nil
  ) -> AnyView {
    let shelf = Samples.backupShelf(
      reports, licence: licence, backingUp: backingUp, progress: progress)
    return AnyView(
      MainView(
        state: shelf,
        navigation: .constant(MainNavigation(page.map { .folder($0) } ?? .allFolders)),
        folderPage: { id in
          guard
            let state = FolderPageState(
              folderID: id, reports: reports, shelf: shelf, backupProgress: progress,
              now: Samples.pageMoment, calendar: Samples.pageCalendar, binName: Samples.binName,
              home: Samples.pageHome)
          else { return AnyView(EmptyView()) }
          return AnyView(FolderPage(state: state, binName: Samples.binName))
        }))
  }
  /// One Backup folder's page alone.
  func page(_ report: FolderReport, backingUp: Set<Int64> = [], progress: RunProgress? = nil)
    -> AnyView
  { window([report], page: report.folder.id, backingUp: backingUp, progress: progress) }

  let own = Samples.backupOwnStates
  let drive = Samples.backupDriveStates
  let documents = own[0]
  let desktop = own[2]

  return [
    ("backup-shelf", window(own, backingUp: [3], progress: working), full),
    ("backup-shelf-account", window(drive), full),
    ("backup-shelf-waiting", window(Samples.backupWaitingStates), full),
    ("backup-shelf-folder", window(Samples.backupFolderStates), full),
    (
      "backup-shelf-paused",
      window(Samples.backupPausedStates, licence: .trialEnded), short
    ),

    ("backup-page-rest", window([documents], page: 1), medium),
    ("backup-page-working", page(desktop, backingUp: [3], progress: working), short),
    ("backup-page-files", page(own[3]), short),
    ("backup-page-failing", page(own[4]), short),
    ("backup-page-signed-out", page(drive[0]), short),
    ("backup-page-full", page(drive[1]), short),
    ("backup-page-bin", page(drive[2]), short),
    ("backup-page-gone", page(drive[3]), short),
    ("backup-page-sign-in", page(drive[5]), short),
    ("backup-page-waiting", page(Samples.backupWaitingStates[0]), short),

    (
      "backup-popover-rest",
      AnyView(MenuBarView(state: Samples.backupPopover(Array(own.prefix(2))))), nil
    ),
    (
      "backup-popover-working",
      AnyView(
        MenuBarView(
          state: Samples.backupPopover([desktop], backingUp: [3], progress: working))), nil
    ),
    (
      "backup-popover-signed-out",
      AnyView(
        MenuBarView(
          state: Samples.backupPopover(
            [
              Samples.backupReport(id: 1, "Documents", drive: .signedOut),
              Samples.backupReport(id: 2, "Pictures", drive: .signedOut),
              Samples.backupReport(id: 3, "Desktop", drive: .signedOut),
              Samples.backupReport(id: 4, "Music", drive: .signedOut),
            ]))), nil
    ),
    (
      "backup-popover-full",
      AnyView(
        MenuBarView(
          state: Samples.backupPopover([
            Samples.backupReport(id: 1, "Documents", drive: .full),
            Samples.backupReport(id: 2, "Pictures", drive: .full),
          ]))), nil
    ),
    ("backup-popover-bin", AnyView(MenuBarView(state: Samples.backupPopover([drive[2]]))), nil),
    ("backup-popover-files", AnyView(MenuBarView(state: Samples.backupPopover([own[3]]))), nil),
    ("backup-popover-failing", AnyView(MenuBarView(state: Samples.backupPopover([own[4]]))), nil),
    (
      "backup-popover-waiting",
      AnyView(MenuBarView(state: Samples.backupPopover([Samples.backupWaitingStates[0]]))), nil
    ),
    ("backup-popover-sign-in", AnyView(MenuBarView(state: Samples.backupPopover([drive[5]]))), nil),

    (
      "backup-finder-menu",
      AnyView(FinderMenuSheet(menu: Samples.backupFinderMenu([documents], folder: "Documents"))),
      nil
    ),
    (
      "backup-finder-menu-needs-you",
      AnyView(
        FinderMenuSheet(
          menu: Samples.backupFinderMenu(
            [
              Samples.backupReport(
                id: 1, "Documents", drive: .signedOut,
                temporary: TemporarySettings(maxAgeDays: 90))
            ],
            folder: "Documents"))),
      nil
    ),
  ]
}
