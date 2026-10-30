import AppKit
import DirBuffUI
import SwiftUI

extension MainContainerView {
  /// History's runs, or only one folder's. A run opens over it.
  func historyPage(folderID: Int64?, now: Date) -> some View {
    HistoryContainerView(
      appModel: appModel, folderID: folderID, now: now,
      onOpenRun: { windowState.navigation.open(.run($0)) })
  }

  /// One run's page.
  func runPage(_ id: Int64, now: Date) -> some View {
    RunContainerView(appModel: appModel, runID: id, now: now)
  }
}

/// When a History page reads again: History changed, a folder that names its runs was added,
/// moved or removed (at launch, the folders arrive after a page the notification opened), or
/// midnight passed and "Today" moved.
private struct HistoryReload: Equatable {
  var revision: Int
  var folders: [String]
  var day: Date

  @MainActor
  init(_ appModel: AppModel, now: Date) {
    revision = appModel.historyRevision
    folders = appModel.reports.map(\.folder.path)
    day = Calendar.current.startOfDay(for: now)
  }
}

/// Reads History when it opens and whenever `HistoryReload` changes.
private struct HistoryContainerView: View {
  var appModel: AppModel
  var folderID: Int64?
  var now: Date
  var onOpenRun: (Int64) -> Void

  @State private var history: HistoryState?

  var body: some View {
    Group {
      if let history {
        HistoryPage(
          folderID: folderID,
          history: history,
          onOpenRun: onOpenRun,
          onClearHistory: appModel.clearHistoryAsking)
      } else {
        Palette.paper.navigationTitle("History")
      }
    }
    .task(id: HistoryReload(appModel, now: now)) { await load() }
  }

  private func load() async {
    history = await appModel.history(now: Date())
  }
}

/// Reads a run when its page opens and whenever `HistoryReload` changes.
private struct RunContainerView: View {
  var appModel: AppModel
  var runID: Int64
  var now: Date

  private enum Loaded {
    case loading
    case gone
    case run(RunState)
  }

  @State private var loaded = Loaded.loading

  var body: some View {
    Group {
      switch loaded {
      case .loading:
        Palette.paper
      case .gone:
        Text("This run is no longer in History.")
          .foregroundStyle(Palette.inkSecondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Palette.paper)
          .navigationSubtitle("History")
      case .run(let run):
        RunPage(run: run, actions: actions)
      }
    }
    .task(id: HistoryReload(appModel, now: now)) { await load() }
  }

  private var actions: RunActions {
    let appModel = appModel
    var actions = RunActions()
    actions.putBack = { ids in Task { await appModel.putBackFromHistory(entryIDs: ids) } }
    actions.showInBin = { path in
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    actions.openFolder = { path in
      NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
    return actions
  }

  private func load() async {
    loaded = await appModel.run(id: runID, now: Date()).map(Loaded.run) ?? .gone
  }
}
