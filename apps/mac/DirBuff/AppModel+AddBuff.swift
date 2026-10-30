import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation

extension AppModel {
  /// Puts a buff on a folder, adding the folder to DirBuff first: from Finder's Add Buff, a drop,
  /// a chosen folder or the welcome window. A protected folder is refused with its reason, and not
  /// added either; one that already wears the buff keeps it, and its settings, as they are.
  /// Returns whether this put the buff on.
  @discardableResult
  func addBuff(_ buff: Buff, toFolderAt url: URL) async -> Bool {
    guard buff == .temporary else { return false }
    if report(for: url)?.folder.wearsTemporary == true { return false }
    guard !System.isProtected(url) else {
      alert(
        "Can't add Temporary to \(url.lastPathComponent)", AppModel.protectedFolderExplanation)
      return false
    }
    guard let folder = await addFolder(url) else { return false }
    return await setTemporary(folder, true)
  }

  /// Takes a buff straight back off right after it was added, from the drop card's Undo.
  func undoAddBuff(_ buff: Buff, on folderID: Int64) async {
    guard buff == .temporary, let folder = folder(id: folderID) else { return }
    await setTemporary(folder, false)
  }

  /// Sets how old things get before they are cleared, from the drop card's pop-up.
  func setMaxAge(days: Int, on folderID: Int64) async {
    guard let folder = folder(id: folderID) else { return }
    var settings = folder.settings
    settings.rule = .age
    settings.maxAgeDays = days
    await save(settings, for: folder)
  }
}
