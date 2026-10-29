import DirBuffUI
import SwiftUI

extension MainContainerView {
  /// A folder's page.
  @ViewBuilder
  func folderPage(_ id: Int64, state: MainState, now: Date) -> some View {
    if let page = FolderPageState(
      folderID: id, reports: appModel.reports, shelf: state, progress: appModel.runProgress,
      now: now)
    {
      FolderPage(state: page, actions: actions, pageActions: pageActions)
    }
  }

  private var pageActions: FolderPageActions {
    let appModel = appModel
    let windowState = windowState
    var pageActions = FolderPageActions()
    pageActions.changeSettings = { id, settings in
      // A late Undo from a toast must not hand settings back to a buff that was taken off: they
      // are forgotten, and adding it again starts from the defaults.
      guard let folder = appModel.folder(id: id),
        folder.wearsTemporary || folder.turnedOffByLicence
      else { return }
      Task { await appModel.save(settings, for: folder) }
    }
    pageActions.openFolder = { id in
      // The switcher swaps this page for the other folder's, so back still goes to the shelf.
      if case .folder = windowState.navigation.path.last {
        windowState.navigation.path[windowState.navigation.path.count - 1] = .folder(id)
      } else {
        windowState.navigation.path.append(.folder(id))
      }
    }
    pageActions.showFiles = { id in windowState.navigation.path.append(.files(id)) }
    pageActions.showAllFolders = { windowState.navigation = MainNavigation() }
    return pageActions
  }
}
