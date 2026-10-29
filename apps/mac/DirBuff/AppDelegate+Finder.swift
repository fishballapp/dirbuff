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
    guard let (action, folderURL) = FinderAction.parse(url) else { return }
    if action.opensSettings(under: appModel.licence) {
      windows.openSettings()
      return
    }
    switch action {
    case .addTemporary:
      Task { await appModel.addBuff(.temporary, toFolderAt: folderURL) }
    case .takeTemporaryOff:
      Task {
        guard let id = appModel.report(for: folderURL)?.folder.id else { return }
        await appModel.confirmTakeOff(.temporary, on: id)
      }
    case .change, .whatsClearedNext, .openFolder:
      Task {
        if appModel.report(for: folderURL) == nil {
          guard await appModel.addFolder(folderURL) != nil else { return }
        }
        if action == .whatsClearedNext, let id = appModel.report(for: folderURL)?.folder.id {
          windows.openMain(route: .files(id))
        } else {
          windows.openMain(selecting: folderURL)
        }
      }
    }
  }
}
