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
      Task {
        guard let folder = await appModel.addFolder(folderURL) else { return }
        let defaults = TemporarySettings()
        if folder.settings != defaults {
          await appModel.save(defaults, for: folder)
        }
        await appModel.setTemporary(folder, true)
      }
    case .takeTemporaryOff:
      Task {
        guard let report = appModel.report(for: folderURL) else { return }
        await appModel.setTemporary(report.folder, false)
      }
    case .change, .whatGoesNext, .openFolder:
      Task {
        if appModel.report(for: folderURL) == nil {
          guard await appModel.addFolder(folderURL) != nil else { return }
        }
        windows.openMain(selecting: folderURL)
      }
    }
  }
}
