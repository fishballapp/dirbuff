import AppKit
import DirBuffUI
import Foundation

extension AppModel {
  /// The menu-bar popover as the folders stand at `now`.
  func popoverState(now: Date) -> PopoverState {
    PopoverState(
      folders: folders(now: now), scheduleLines: scheduleLines(reports, now: now),
      progress: runProgress, licence: licence, now: now)
  }

  /// Opens the place where the fix is made.
  func perform(_ fix: Fix, on folderID: Int64) {
    switch fix {
    case .giveAccess: openFilesAndFoldersSettings()
    case .locate: Task { await locate(folderID: folderID) }
    // Backup isn't wearable yet, so none of these shows. Ticket 8 gives each its own action.
    case .backUpNow, .showFiles, .showDetails: showFolderPage(folderID)
    case .signInAgain, .makeRoom, .startAgain, .putBackFromDriveBin: showSettings()
    }
  }

  /// Sets where the fixes that open a window lead.
  func connectFixes(showFolderPage: @escaping (Int64) -> Void, showSettings: @escaping () -> Void) {
    self.showFolderPage = showFolderPage
    self.showSettings = showSettings
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
