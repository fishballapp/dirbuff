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
    switch buff {
    case .temporary: break
    case .backup:
      if report(for: url)?.backupWear != nil { return false }
      guard let folder = await addFolder(url) else { return false }
      return await setBackup(folder, true)
    case .organise, .search: return false
    }
    if let wear = report(for: url)?.temporaryWear, !wear.isPausedByLicence { return false }
    if let refusal = temporary.refusal(for: url) {
      alert("Can't add Temporary to \(url.lastPathComponent)", AppModel.explain(refusal))
      return false
    }
    guard let folder = await addFolder(url) else { return false }
    return await setTemporary(folder, true)
  }

  /// Puts a buff on a folder DirBuff knows; returns whether it went on.
  @discardableResult
  func addBuff(_ buff: Buff, on folderID: Int64) async -> Bool {
    guard let folder = folder(id: folderID) else { return false }
    switch buff {
    case .temporary: return await setTemporary(folder, true)
    case .backup: return await setBackup(folder, true)
    case .organise, .search: return false
    }
  }

  /// Takes a buff straight back off right after it was added, from the drop card's Undo.
  func undoAddBuff(_ buff: Buff, on folderID: Int64) async {
    guard let folder = folder(id: folderID) else { return }
    switch buff {
    case .temporary: await setTemporary(folder, false)
    case .backup: await setBackup(folder, false)
    case .organise, .search: break
    }
  }

  /// Sets how old things get before they are cleared, from the drop card's pop-up.
  func setMaxAge(days: Int, on folderID: Int64) async {
    guard let folder = folder(id: folderID),
      var settings = report(id: folderID)?.temporaryWear?.settings
    else { return }
    settings.rule = .age
    settings.maxAgeDays = days
    await save(settings, for: folder)
  }
}
