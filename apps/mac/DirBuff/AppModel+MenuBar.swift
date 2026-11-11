import AppKit
import DirBuffUI
import Foundation

extension AppModel {
  /// The menu-bar popover as the folders stand at `now`.
  func popoverState(now: Date) -> PopoverState {
    PopoverState(
      folders: folders(now: now), scheduleLines: scheduleLines(reports, now: now),
      progress: runProgress, backupProgress: backupProgress, restore: restoreRun, licence: licence,
      now: now)
  }

  /// Makes the fix, or opens the place where it's made.
  func perform(_ fix: Fix, on folderID: Int64) {
    switch fix {
    case .giveAccess: openFilesAndFoldersSettings()
    case .locate: Task { await locate(folderID: folderID) }
    case .backUpNow: perform(BackupCommand.backUpNow)
    case .showFiles: showMain(MainNavigation(opening: .unreadFiles(folderID)))
    case .showDetails: showBackupDetails(folderID: folderID)
    // Signed in to another account, the sheet opens at the step that says whose Drive it is in.
    case .signInAgain, .chooseAccount:
      showFolderPage(folderID)
      askToSignIn(.signInAgain)
    case .putBackFromDriveBin: Task { await putBackBackup() }
    case .makeRoom: makeRoom()
    case .startAgain: Task { await confirmStartAgain() }
    }
  }

  /// Sets where the fixes that open a window lead.
  func connectFixes(
    showFolderPage: @escaping (Int64) -> Void, showSettings: @escaping () -> Void,
    showMain: @escaping (MainNavigation?) -> Void
  ) {
    self.showFolderPage = showFolderPage
    self.showSettings = showSettings
    self.showMain = showMain
  }

  /// Privacy & Security's Files and Folders, where a folder's access is given back to DirBuff.
  private func openFilesAndFoldersSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
    else { return }
    NSWorkspace.shared.open(url)
  }
}
