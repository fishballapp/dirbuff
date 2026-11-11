import DirBuffUI
import Foundation
import SwiftUI

extension MainContainerView {
  /// A folder's page, its sidebar row's.
  @ViewBuilder
  func folderPage(_ id: Int64, state: MainState, now: Date) -> some View {
    if let page = FolderPageState(
      folderID: id, reports: appModel.reportsWithDrive, shelf: state,
      progress: appModel.runProgress, backupProgress: appModel.backupProgress,
      googleAccount: appModel.googleAccount, backupAttempts: appModel.backupAttempts[id] ?? [],
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
      guard let report = appModel.report(id: id), report.temporaryWear != nil else { return }
      Task { await appModel.save(settings, for: report.folder) }
    }
    pageActions.changeBackupSettings = { id, settings in
      // As for Temporary: a late Undo mustn't reach a Backup that was taken off.
      guard appModel.report(id: id)?.backupWear != nil else { return }
      Task { await appModel.save(settings, folderID: id) }
    }
    pageActions.bringBack = { id, item in Task { await appModel.bringBack(item, folderID: id) } }
    pageActions.signIn = { id in
      guard let folder = appModel.folder(id: id) else { return }
      appModel.askToSignIn(
        .backUp(
          folderName: URL(fileURLWithPath: folder.path).lastPathComponent, folderPath: folder.path))
    }
    pageActions.showVersions = { id in windowState.navigation.open(.versions(id)) }
    pageActions.showFiles = { id in windowState.navigation.open(.files(id)) }
    pageActions.showHistory = { id in windowState.navigation.open(.folderHistory(id)) }
    return pageActions
  }
}
