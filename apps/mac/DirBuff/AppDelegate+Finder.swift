import AppKit
import DirBuffCore
import DirBuffUI

extension AppDelegate {
  /// Routes `dirbuff://` URLs handed off by the Finder extension.
  func handleFinder(urls: [URL]) {
    for url in urls {
      handleFinder(url)
    }
  }

  private func handleFinder(_ url: URL) {
    if let command = BackupCommand.parse(url) {
      appModel.perform(command)
      return
    }
    guard let (action, folderURL) = FinderAction.parse(url) else { return }
    // Any app or web page can open a `dirbuff://` URL: a buff goes only on a folder the user can
    // see, as a drop's does.
    if action == .addTemporary || action == .addBackup, !isFolderForABuff(folderURL) { return }
    if action.opensSettings(under: appModel.licence) {
      windows.openSettings()
      return
    }
    switch action {
    case .addTemporary:
      Task { await appModel.addBuff(.temporary, toFolderAt: folderURL) }
    case .addBackup:
      // It starts uploading the folder, so it asks first, before anything is added.
      guard appModel.report(for: folderURL)?.backupWear == nil else { return }
      NSApp.activate(ignoringOtherApps: true)
      let alert = BackupAlert.addBackup(folderName: folderURL.lastPathComponent).makeAlert()
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      Task {
        // Open at the folder first: putting Backup on while signed out asks on the main window.
        if appModel.report(for: folderURL) == nil {
          guard await appModel.addFolder(folderURL) != nil else { return }
        }
        windows.openMain(selecting: folderURL)
        await appModel.addBuff(.backup, toFolderAt: folderURL)
      }
    case .takeTemporaryOff, .takeBackupOff:
      Task {
        guard let id = appModel.report(for: folderURL)?.folder.id else { return }
        await appModel.confirmTakeOff(action == .takeBackupOff ? .backup : .temporary, on: id)
      }
    case .change, .whatsClearedNext, .openFolder:
      Task {
        if appModel.report(for: folderURL) == nil {
          guard await appModel.addFolder(folderURL) != nil else { return }
        }
        if action == .whatsClearedNext, let id = appModel.report(for: folderURL)?.folder.id {
          windows.openMain(at: MainNavigation(opening: .files(id)))
        } else {
          windows.openMain(selecting: folderURL)
        }
      }
    }
  }
}
