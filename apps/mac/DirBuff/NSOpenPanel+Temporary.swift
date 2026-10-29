import AppKit
import DirBuffKit

extension NSOpenPanel {
  /// Asks which folder to make Temporary: from + Buff, a tile's menu or the welcome window. A
  /// protected folder is refused with its reason, and the panel stays open.
  @MainActor
  static func chooseFolderToMakeTemporary() -> URL? {
    let panel = NSOpenPanel()
    // The panel holds its delegate weakly.
    let delegate = ProtectedFolderRefusal()
    panel.delegate = delegate
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.message = "Choose a folder to make Temporary"
    panel.prompt = "Add"
    guard withExtendedLifetime(delegate, { panel.runModal() }) == .OK else { return nil }
    return panel.url
  }
}

/// Refuses a protected folder when Add is clicked, so the panel stays open and says why. Disabling
/// it instead would also stop the user opening it, and Downloads is inside the home folder.
private final class ProtectedFolderRefusal: NSObject, NSOpenSavePanelDelegate {
  func panel(_ sender: Any, validate url: URL) throws {
    guard System.isProtected(url) else { return }
    throw NSError(
      domain: "app.fishball.dirbuff", code: 1,
      userInfo: [NSLocalizedDescriptionKey: AppModel.protectedFolderExplanation])
  }
}
