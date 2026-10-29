import AppKit

extension AppModel {
  /// Shows files or folders in Finder, selected.
  func showInFinder(_ urls: [URL]) {
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }
}
