import AppKit
import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation

extension AppModel {
  /// Main-window state with live working folders and resolved protected roots.
  func shelfState(now: Date) -> MainState {
    MainState(
      reports: reports,
      licence: licence(now: now),
      working: working,
      progress: runProgress,
      now: now,
      protectedPaths: Set(System.protectedFolderPaths())
    )
  }

  /// The folder DirBuff knows by `id`, as last read.
  func folder(id: Int64) -> Folder? {
    reports.first(where: { $0.folder.id == id })?.folder
  }

  /// Asks where a missing folder went, and points DirBuff at the folder the user chooses.
  func locate(folderID: Int64) async {
    guard let report = reports.first(where: { $0.folder.id == folderID }) else { return }
    let name = URL(fileURLWithPath: report.folder.path).lastPathComponent
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.message = "Where is \(name) now?"
    panel.prompt = "Locate"
    // From the menu bar no window is open, so DirBuff comes to the front for the panel.
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let engine = engine
    do {
      try await Task.detached { try engine.relocate(folderID: folderID, to: url) }.value
    } catch {
      show(error, doing: "locate \(name)")
    }
    await refresh()
  }

  /// Forgets a folder after asking. Its files are left alone.
  func removeFolderAsking(folderID: Int64) async {
    guard let folder = reports.first(where: { $0.folder.id == folderID })?.folder else { return }
    let name = URL(fileURLWithPath: folder.path).lastPathComponent
    let alert = NSAlert()
    alert.messageText = "Remove \(name) from DirBuff?"
    alert.informativeText = "DirBuff forgets it and its settings. Nothing in the folder is touched."
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    await remove(folder)
  }
}
