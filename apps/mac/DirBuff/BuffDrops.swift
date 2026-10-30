import DirBuffUI
import Foundation

extension AppModel {
  /// Tells a dragged buff what a drop on a Finder folder does, and what the drop card's pop-up
  /// changes. Set once at launch, so a buff drops into Finder from any window.
  ///
  /// - Parameter openSettings: Opens Settings, where the Licence section leads, for a buff
  ///   dropped while every buff is paused.
  func connectBuffDrops(openSettings: @escaping () -> Void) {
    let host = AddBuffHost.shared
    host.addToFinderFolder = { [weak self] buff, folder in
      guard let self else { return }
      // As Finder's Add Buff: adding a buff that can't run would be a silent dead end.
      guard licence.mayClean else {
        openSettings()
        return
      }
      // A promise lands wherever the drop names: a folder in Finder, or, dropped on another app,
      // a hidden folder of that app's. Only a folder the user can see takes a buff.
      guard Self.isUserFolder(folder) else { return }
      Task { await self.addBuff(buff, toFolderAt: folder) }
    }
    host.setMaxAge = { [weak self] folderID, days in
      Task { await self?.setMaxAge(days: days, on: folderID) }
    }
  }

  private static func isUserFolder(_ url: URL) -> Bool {
    let path = url.resolvingSymlinksInPath().path
    let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    let hidden = url.pathComponents.contains { $0.hasPrefix(".") }
    // iCloud Drive and cloud-storage folders live in the user's Library, and are theirs.
    let cloud = ["Mobile Documents", "CloudStorage"].map {
      library.appendingPathComponent($0).path + "/"
    }
    if cloud.contains(where: path.hasPrefix) { return !hidden }
    let system = ["/private/", "/System/", "/Library/", library.path + "/"].contains {
      path.hasPrefix($0)
    }
    return !hidden && !system
  }
}
