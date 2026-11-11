import DirBuffUI
import Foundation
import SwiftUI

extension MainContainerView {
  /// What is cleared next from a folder.
  @ViewBuilder
  func filesPage(_ id: Int64, state: MainState, now: Date) -> some View {
    if let folder = state.folders.first(where: { $0.id == id }) {
      FolderFilesPage(
        folder: folder,
        folderState: state.shelfFolders.first { $0.id == id },
        now: now,
        isPaused: !state.mayClean,
        onShowInFinder: appModel.showInFinder,
        onFix: { appModel.perform($0, on: id) },
        onShowHistory: { windowState.navigation.open(.folderHistory(id)) }
      )
    }
  }

  /// Show Files: what the last backup of a folder couldn't read, each with Leave Out.
  @ViewBuilder
  func unreadFilesPage(_ id: Int64) -> some View {
    if let folder = appModel.folder(id: id) {
      UnreadFilesPage(
        state: appModel.unreadFiles(folderID: id),
        folderName: URL(fileURLWithPath: folder.path).lastPathComponent,
        folderPath: folder.path,
        onLeaveOut: { file in Task { await appModel.leaveOut(file, folderID: id) } },
        onShowInFinder: appModel.showInFinder,
        onShowVersions: { windowState.navigation.open(.versions(id)) }
      )
    }
  }
}
