import DirBuffUI
import Foundation
import SwiftUI

extension MainContainerView {
  /// Show Versions…: the Backup folder's files with a past.
  @ViewBuilder
  func versionsPage(_ id: Int64) -> some View {
    if appModel.folder(id: id) != nil {
      VersionsPageContainer(appModel: appModel, folderID: id)
    }
  }
}

/// Reads the folder's versions off the main actor when the page opens and after each backup, so a
/// redraw never reads the database.
private struct VersionsPageContainer: View {
  var appModel: AppModel
  var folderID: Int64

  @State private var versions: VersionsState?

  var body: some View {
    Group {
      if let versions {
        VersionsPage(
          state: versions,
          copyingID: appModel.versionsCopying,
          toast: appModel.versionsToast,
          onRestoreCopy: { file in Task { await appModel.restoreCopy(file, folderID: folderID) } },
          onRestoreFolder: { appModel.askToRestoreFolder(folderID: folderID) },
          onShowInFinder: appModel.showInFinder,
          onShowCopy: { appModel.showInFinder([$0]) })
      } else {
        Color.clear
      }
    }
    .task(id: appModel.backupAttempts[folderID]?.first?.startedAt) {
      versions = await appModel.versionsState(folderID: folderID, now: Date())
    }
    .task(id: appModel.versionsToast) {
      guard appModel.versionsToast != nil else { return }
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      appModel.dismissVersionsToast()
    }
    .onDisappear { appModel.dismissVersionsToast() }
  }
}
