import AppKit
import DirBuffUI
import SwiftUI

/// The floating Buffs panel: + Buff torn off, or opened from Window › Buffs. It floats above every
/// window, Finder's too, and never takes the focus, so a piece drags from it straight into Finder.
/// It also tells the buffs what a drop on a Finder folder does, and what the drop card's pop-up
/// changes.
@MainActor
final class BuffsPanelController {
  private lazy var panel: NSPanel = makePanel()

  /// - Parameter openSettings: Opens Settings, where the Licence section leads, for a buff
  ///   dropped while every buff is paused.
  init(appModel: AppModel, openSettings: @escaping () -> Void) {
    let host = AddBuffHost.shared
    host.addToFinderFolder = { buff, folder in
      // As Finder's Add Buff: adding a buff that can't run would be a silent dead end.
      guard appModel.licence.mayClean else {
        openSettings()
        return
      }
      // A promise lands wherever the drop names: a folder in Finder, or, dropped on another app,
      // a hidden folder of that app's. Only a folder the user can see takes a buff.
      guard Self.isUserFolder(folder) else { return }
      Task { await appModel.addBuff(buff, toFolderAt: folder) }
    }
    host.setMaxAge = { folderID, days in
      Task { await appModel.setMaxAge(days: days, on: folderID) }
    }
    host.buffsPanel = { [weak self] in self?.panel }
  }

  private static func isUserFolder(_ url: URL) -> Bool {
    let path = url.resolvingSymlinksInPath().path
    let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    let hidden = url.pathComponents.contains { $0.hasPrefix(".") }
    let system = ["/private/", "/System/", "/Library/", library.path + "/"].contains {
      path.hasPrefix($0)
    }
    return !hidden && !system
  }

  func show() {
    panel.orderFrontRegardless()
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
      backing: .buffered,
      defer: true)
    panel.title = "Buffs"
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.fullScreenAuxiliary]
    let content = NSHostingView(rootView: BuffsPanelView())
    panel.contentView = content
    panel.setContentSize(content.fittingSize)
    panel.center()
    panel.setFrameAutosaveName("DirBuffBuffs")
    return panel
  }
}
