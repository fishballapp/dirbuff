import AppKit
import DirBuffCore
import DirBuffKit
import DirBuffUI
import SwiftUI

/// DirBuff's main window content: binds the app model's state and actions to `MainView`. Each
/// pushed page is built in its own `MainContainerView+<Page>` file.
struct MainContainerView: View {
  var appModel: AppModel
  @Bindable var windowState: MainWindowState
  var coordinator: WindowCoordinator

  var body: some View {
    TimelineView(CountdownSchedule()) { timeline in
      mainView(now: timeline.date)
    }
  }

  private func mainView(now: Date) -> some View {
    let state = appModel.shelfState(now: now)
    return MainView(
      state: state,
      navigation: $windowState.navigation,
      actions: actions,
      destination: { route in destination(route, state: state, now: now) }
    )
  }

  private func destination(_ route: MainRoute, state: MainState, now: Date) -> AnyView {
    switch route {
    case .folder(let id): AnyView(folderPage(id, state: state, now: now))
    case .files(let id): AnyView(filesPage(id, state: state, now: now))
    case .history(let folderID): AnyView(historyPage(folderID: folderID, now: now))
    case .run(let id): AnyView(runPage(id, now: now))
    }
  }

  /// Every shelf action, wired to the app; pages built in other files use it too.
  var actions: ShelfActions {
    let appModel = appModel
    var actions = ShelfActions()
    actions.chooseFolderForBuff = chooseFolderForBuff
    actions.addBuff = { id, buff in
      guard buff == .temporary, let folder = appModel.folder(id: id) else { return }
      Task { await appModel.setTemporary(folder, true) }
    }
    actions.undoAddBuff = { id, buff in Task { await appModel.undoAddBuff(buff, on: id) } }
    actions.takeOff = { id, buff in Task { await appModel.confirmTakeOff(buff, on: id) } }
    actions.fix = { id, fix in appModel.perform(fix, on: id) }
    actions.locate = { id in Task { await appModel.locate(folderID: id) } }
    actions.removeFolder = { id in Task { await appModel.removeFolderAsking(folderID: id) } }
    actions.showInFinder = { id in
      guard let folder = appModel.folder(id: id) else { return }
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
    }
    actions.openLicenceSettings = coordinator.openSettings
    actions.buy = appModel.openCheckout
    actions.enterKey = coordinator.openKeyEntry
    actions.checkLicence = { Task { await appModel.checkLicenceNow() } }
    return actions
  }

  private func chooseFolderForBuff(_ buff: Buff) {
    guard buff == .temporary else { return }
    let panel = NSOpenPanel()
    // The panel holds its delegate weakly.
    let delegate = ProtectedFolderRefusal()
    panel.delegate = delegate
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.message = "Choose a folder to make Temporary"
    panel.prompt = "Add"
    guard withExtendedLifetime(delegate, { panel.runModal() }) == .OK, let url = panel.url else {
      return
    }
    Task {
      await appModel.addFolderWearingTemporary(url)
      windowState.navigation = MainNavigation()
    }
  }
}

/// Refuses a protected folder when Add is clicked, so the panel stays open and says why. Disabling
/// it instead would also stop the user opening it, and Downloads is inside the home folder.
private final class ProtectedFolderRefusal: NSObject, NSOpenSavePanelDelegate {
  func panel(_ sender: Any, validate url: URL) throws {
    guard System.isProtected(url) else { return }
    throw NSError(
      domain: "app.fishball.dirbuff", code: 1,
      userInfo: [NSLocalizedDescriptionKey: AppModel.protectedFolderExplanation])
  }
}
