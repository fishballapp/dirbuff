import DirBuffUI
import SwiftUI

extension MainContainerView {
  /// A folder's page, its sidebar row's.
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
    pageActions.showFiles = { id in windowState.navigation.open(.files(id)) }
    pageActions.showHistory = { id in windowState.navigation.open(.folderHistory(id)) }
    return pageActions
  }
}
