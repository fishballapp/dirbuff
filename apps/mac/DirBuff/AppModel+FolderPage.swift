import AppKit
import DirBuffUI
import Foundation

extension AppModel {
  /// Takes a buff off a folder after asking, from its card, its tile or Finder: its settings will
  /// be forgotten, so adding it again starts from the defaults.
  func confirmTakeOff(_ buff: Buff, on folderID: Int64) async {
    guard buff == .temporary, let folder = folder(id: folderID) else { return }
    let name = URL(fileURLWithPath: folder.path).lastPathComponent
    let alert = NSAlert()
    alert.messageText = "Take Temporary off \(name)?"
    alert.informativeText = "Its settings will be forgotten."
    alert.addButton(withTitle: "Take Off")
    alert.addButton(withTitle: "Cancel")
    // From Finder, DirBuff isn't the active app, and its alert would open behind Finder.
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    await setTemporary(folder, false)
  }
}
