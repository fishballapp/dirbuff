import DirBuffUI
import Foundation

extension AppModel {
  /// Takes a buff straight back off right after it was added, from the drop card's Undo.
  func undoAddBuff(_ buff: Buff, on folderID: Int64) async {
    guard buff == .temporary, let folder = folder(id: folderID) else { return }
    await setTemporary(folder, false)
  }
}
