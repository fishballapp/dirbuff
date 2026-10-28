import DirBuffUI
import SwiftUI

extension MainContainerView {
  /// What goes next from a folder.
  @ViewBuilder
  func filesPage(_ id: Int64, state: MainState, now: Date) -> some View {
    if let folder = state.folders.first(where: { $0.id == id }) {
      FolderFilesPage(folder: folder)
    }
  }
}
