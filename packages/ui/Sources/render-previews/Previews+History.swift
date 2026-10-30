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
        history: { AnyView(HistoryPage(folderID: nil, history: history)) },
        page: { page in
          switch page {
          case .folderHistory(let id): AnyView(HistoryPage(folderID: id, history: history))
          case .run: AnyView(RunPage(run: Samples.run))
          case .files: AnyView(EmptyView())
          }
        }))
  }
  return [
    ("history-list", window(MainNavigation(.history)), size),
    // The foot under the list, with fewer runs so it's in the window.
    (
      "history-list-foot",
      window(
        MainNavigation(.history),
        history: HistoryState(
          runs: Array(Samples.history.runs.prefix(6)), folders: Samples.history.folders)),
      size
    ),
    (
      "history-list-folder",
      window(MainNavigation(opening: .folderHistory(1))), size
    ),
    ("history-empty", window(MainNavigation(.history), history: HistoryState()), size),
    ("history-run", window(MainNavigation(opening: .run(1))), size),
  ]
}
