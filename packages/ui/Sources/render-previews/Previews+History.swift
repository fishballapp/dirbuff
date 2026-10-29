import DirBuffUI
import SwiftUI

/// History's runs, one folder's, none yet, and a run's page, each in the main window.
@MainActor
func historyPreviews() -> [Preview] {
  let size = CGSize(width: 1240, height: 800)
  func window(_ navigation: MainNavigation, history: HistoryState = Samples.history) -> AnyView {
    AnyView(
      MainView(
        state: Samples.historyShelf,
        navigation: .constant(navigation),
        destination: { route in
          switch route {
          case .history(let folderID): AnyView(HistoryPage(folderID: folderID, history: history))
          case .run: AnyView(RunPage(run: Samples.run))
          case .folder, .files: AnyView(EmptyView())
          }
        }))
  }
  return [
    ("history-list", window(MainNavigation(root: .history)), size),
    // The foot under the list, with fewer runs so it's in the window.
    (
      "history-list-foot",
      window(
        MainNavigation(root: .history),
        history: HistoryState(
          runs: Array(Samples.history.runs.prefix(6)), folders: Samples.history.folders)),
      size
    ),
    (
      "history-list-folder",
      window(MainNavigation(root: .shelf, path: [.folder(1), .history(folderID: 1)])), size
    ),
    ("history-empty", window(MainNavigation(root: .history), history: HistoryState()), size),
    ("history-run", window(MainNavigation(opening: .run(1))), size),
  ]
}
