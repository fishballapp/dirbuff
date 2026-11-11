import Foundation

/// Whether a buff may go on `url` when something outside DirBuff's window names it: a
/// `dirbuff://` URL, which any app or web page can open, or a buff dropped into Finder, whose
/// promise lands wherever the drop names. Only an existing folder (not a file, nor a package such
/// as an app) that the user can see: nothing hidden, and nothing of the system's or of Library's,
/// but iCloud Drive and cloud-storage folders, which live in Library and are the user's.
public func isFolderForABuff(_ url: URL) -> Bool {
  guard
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
    values.isDirectory == true, values.isPackage != true
  else { return false }
  let path = url.resolvingSymlinksInPath().path
  let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
  let hidden = url.pathComponents.contains { $0.hasPrefix(".") }
  let cloud = ["Mobile Documents", "CloudStorage"].map {
    library.appendingPathComponent($0).path + "/"
  }
  if cloud.contains(where: path.hasPrefix) { return !hidden }
  let system = ["/private/", "/System/", "/Library/", library.path + "/"].contains {
    path.hasPrefix($0)
  }
  return !hidden && !system
}
