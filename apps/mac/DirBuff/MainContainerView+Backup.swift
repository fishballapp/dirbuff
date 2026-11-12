import DirBuffUI
import Foundation
import QuickLook
import SwiftUI

extension MainContainerView {
  /// Browse Backup…: the backup page of a Backup folder.
  @ViewBuilder
  func backupPage(_ id: Int64) -> some View {
    if let folder = appModel.folder(id: id) {
      BackupPageContainer(appModel: appModel, folderID: id, folderPath: folder.path)
    }
  }
}

/// Holds the page's model for as long as the page is open, and reads the backups again after
/// each backup of the folder.
private struct BackupPageContainer: View {
  var appModel: AppModel
  var folderID: Int64
  @State private var model: BackupPageModel

  init(appModel: AppModel, folderID: Int64, folderPath: String) {
    self.appModel = appModel
    self.folderID = folderID
    _model = State(
      initialValue: BackupPageModel(appModel: appModel, folderID: folderID, folderPath: folderPath))
  }

  var body: some View {
    TimelineView(.everyMinute) { timeline in
      BackupPage(state: state, now: timeline.date, actions: actions)
    }
    .quickLookPreview($model.quickLookURL)
    .task { await model.loadBackups() }
    .task(id: appModel.backupAttempts[folderID]?.first?.startedAt) { await model.refresh() }
    .onDisappear { model.close() }
  }

  /// The page's state, with what Backup's schedule is running now, which its work waits behind.
  private var state: BackupBrowserState {
    var state = model.state
    state.busyWith = appModel.resticJob
    return state
  }

  private var actions: BackupPageActions {
    let model = model
    var actions = BackupPageActions()
    actions.selectBackup = model.selectBackup
    actions.select = model.select
    actions.move = model.move
    actions.showEntry = model.show
    actions.retry = model.retry
    actions.fix = model.fix
    actions.restore = model.restore
    actions.cancelRestore = model.cancelRestore
    actions.restoreFolder = model.restoreFolder
    actions.quickLook = model.showQuickLook
    actions.showInFinder = appModel.showInFinder
    actions.prepareDragOut = model.prepareDragOut
    actions.submitPassword = model.submitPassword
    actions.cancelPassword = model.cancelPassword
    return actions
  }
}
