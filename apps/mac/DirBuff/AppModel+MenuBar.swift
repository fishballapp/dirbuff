import AppKit
import DirBuffUI
import Foundation

extension AppModel {
  /// The menu-bar popover as the folders stand at `now`.
  func popoverState(now: Date) -> PopoverState {
    PopoverState(folders: folders(now: now), licence: licence, now: now)
  }

  /// Opens the place where the fix is made.
  func perform(_ fix: Fix) {
    switch fix {
    case .giveAccess: openFilesAndFoldersSettings()
    }
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
