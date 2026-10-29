import SwiftUI

/// History's list of runs, newest first, as one card; with a folder, only the runs that touched it.
/// A row opens its run's page. Under the list, how long runs are kept, and Clear History….
public struct HistoryPage: View {
  public var folderID: Int64?
  public var history: HistoryState
  public var onClearHistory: () -> Void

  public init(
    folderID: Int64?,
    history: HistoryState,
    onClearHistory: @escaping () -> Void = {}
  ) {
    self.folderID = folderID
    self.history = history
    self.onClearHistory = onClearHistory
  }

  public var body: some View {
    let runs = history.runs(touching: folderID)
    Group {
      if runs.isEmpty {
        empty
      } else {
        list(runs)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.paper)
    .navigationTitle("History")
    .navigationSubtitle(history.subtitle(for: folderID))
  }

  private func list(_ runs: [HistoryRunRow]) -> some View {
    ScrollView {
      VStack(spacing: 16) {
        LazyVStack(spacing: 0) {
          ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
            if index > 0 {
              Palette.rule
                .frame(height: 1)
                .padding(.leading, 58)
            }
            NavigationLink(value: MainRoute.run(run.id)) {
              HistoryRunRowView(run: run)
            }
            .buttonStyle(.plain)
          }
        }
        .historyCard()

        HStack(spacing: 14) {
          Text("Keeps the last 100 MB of runs.")
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
          // Clearing forgets every run, so it stays off a list that shows only one folder's.
          if folderID == nil {
            Button("Clear History…", action: onClearHistory)
          }
        }
      }
      .padding(32)
    }
  }

  private var empty: some View {
    VStack(spacing: 6) {
      Text("No runs yet")
        .font(.headline)
        .foregroundStyle(Palette.inkSecondary)
      Text("Every clean-up that removes something is listed here.")
        .foregroundStyle(Palette.inkTertiary)
    }
    .padding(32)
  }
}
