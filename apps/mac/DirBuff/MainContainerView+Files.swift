import DirBuffUI
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
}
