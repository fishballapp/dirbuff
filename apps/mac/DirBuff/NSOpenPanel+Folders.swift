import AppKit
import DirBuffKit

extension NSOpenPanel {
  /// Asks which folder to add to DirBuff, wearing nothing yet: from + Folder and the sidebar's +.
  /// A protected folder can be added; Temporary refuses it later, with its reason.
  @MainActor
  static func chooseFolderToAdd() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.message = "Choose a folder to add to DirBuff"
    panel.prompt = "Add"
    return panel.runModal() == .OK ? panel.url : nil
  }

  /// Asks which folder to make Temporary: from a buff's Add to Folder › Other Folder… or the
  /// welcome window. A protected folder is refused with its reason, and the panel stays open.
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
