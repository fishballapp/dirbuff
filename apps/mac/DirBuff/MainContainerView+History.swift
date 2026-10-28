import DirBuffUI
import SwiftUI

extension MainContainerView {
  /// History's runs, or only one folder's.
  func historyPage(folderID: Int64?, now: Date) -> some View {
    HistoryPage(folderID: folderID)
  }

  /// One run's page.
  func runPage(_ id: Int64, now: Date) -> some View {
    RunPage(runID: id)
  }
}
