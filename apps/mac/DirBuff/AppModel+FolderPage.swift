import AppKit
import DirBuffUI
import Foundation

extension AppModel {
  /// Takes a buff off a folder after asking: its settings will be forgotten.
  func confirmTakeOff(_ buff: Buff, on folderID: Int64) async {
    guard buff == .temporary, let folder = folder(id: folderID) else { return }
    let name = URL(fileURLWithPath: folder.path).lastPathComponent
    let alert = NSAlert()
    alert.messageText = "Take Temporary off \(name)?"
    alert.informativeText = "Its settings will be forgotten."
    alert.addButton(withTitle: "Take Off")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    await setTemporary(folder, false)
  }
}
