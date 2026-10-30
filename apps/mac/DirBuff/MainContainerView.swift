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
      folderPage: { AnyView(folderPage($0, state: state, now: now)) },
      history: { AnyView(historyPage(folderID: nil, now: now)) },
      page: { page in
        switch page {
        case .files(let id): AnyView(filesPage(id, state: state, now: now))
        case .folderHistory(let id): AnyView(historyPage(folderID: id, now: now))
        case .run(let id): AnyView(runPage(id, now: now))
        }
      }
    )
  }

  /// Every shelf action, wired to the app; pages built in other files use it too.
  var actions: ShelfActions {
    let appModel = appModel
    var actions = ShelfActions()
    actions.addFolder = addFolder
    actions.chooseFolderForBuff = chooseFolderForBuff
    actions.addBuff = { id, buff in
      guard buff == .temporary, let folder = appModel.folder(id: id) else { return false }
      return await appModel.setTemporary(folder, true)
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

  /// Adds the folder the user chooses, wearing nothing, and opens its page; one already added
  /// just opens.
  private func addFolder() {
    guard let url = NSOpenPanel.chooseFolderToAdd() else { return }
    Task {
      guard let id = await appModel.addFolder(url)?.id else { return }
      windowState.navigation = MainNavigation(.folder(id))
    }
  }

  private func chooseFolderForBuff(_ buff: Buff) {
    guard buff == .temporary else { return }
    guard let url = NSOpenPanel.chooseFolderToMakeTemporary() else { return }
    Task {
      await appModel.addBuff(.temporary, toFolderAt: url)
      guard let id = appModel.report(for: url)?.folder.id else { return }
      windowState.navigation = MainNavigation(.folder(id))
    }
  }
}
