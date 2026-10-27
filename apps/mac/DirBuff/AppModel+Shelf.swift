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
      now: now,
      protectedPaths: Set(System.protectedFolderPaths())
    )
  }

  /// Adds `url` to DirBuff and puts Temporary on it in one step (toolbar + Buff › Temporary).
  @discardableResult
  func addFolderWearingTemporary(_ url: URL) async -> Folder? {
    guard let folder = await addFolder(url) else { return nil }
    await setTemporary(folder, true)
    return reports.first(where: { $0.folder.id == folder.id })?.folder ?? folder
  }

  /// Puts a buff back on a folder during its one-day Put Back window after Take Off.
  func putBackBuff(_ buff: Buff, on folderID: Int64) async {
    guard buff == .temporary,
      let report = reports.first(where: { $0.folder.id == folderID })
    else { return }
    guard report.folder.putBackUntil.map({ Date() < $0 }) == true else {
      let folderName = URL(fileURLWithPath: report.folder.path).lastPathComponent
      let alert = NSAlert()
      alert.messageText = "Couldn't make \(folderName) Temporary"
      alert.informativeText = "Temporary can't be put back on that folder any more."
      alert.runModal()
      await refresh()
      return
    }
    await setTemporary(report.folder, true)
  }
}
