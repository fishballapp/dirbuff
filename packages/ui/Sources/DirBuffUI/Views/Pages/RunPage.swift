import SwiftUI

/// What a run's page does: bring things back from the Bin, and show them or their folder in Finder.
public struct RunActions {
  /// Puts back the journal entries' items, with no confirmation: one file's, or a folder's all.
  public var putBack: ([Int64]) -> Void = { _ in }
  /// Shows an item in the Bin, selected.
  public var showInBin: (String) -> Void = { _ in }
  /// Opens a folder in Finder.
  public var openFolder: (String) -> Void = { _ in }

  public init() {}
}

/// One run's page, pushed over History: the large symbol, when it ran and what it removed, then
/// one group per folder with where each file ended up. Every action in the list is a ghost icon button.
public struct RunPage: View {
  public var run: RunState
  public var actions: RunActions

  public init(run: RunState, actions: RunActions = RunActions()) {
    self.run = run
    self.actions = actions
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        RunFilesTable(groups: run.groups, actions: actions)
          .historyCard()
      }
      .padding(.top, 28)
      .padding(.horizontal, 40)
      .padding(.bottom, 32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.paper)
    .navigationTitle(run.title)
    .navigationSubtitle("History")
  }

  private var header: some View {
    HStack(spacing: 18) {
      BuffSymbol(run.buff, width: 54)
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 6)
      VStack(alignment: .leading, spacing: 2) {
        Text(run.title)
          .font(.title)
          .bold()
          .foregroundStyle(Palette.ink)
        Text(run.subtitle)
          .font(.callout)
          .foregroundStyle(Palette.inkTertiary)
      }
      .monospacedDigit()
    }
    .padding(.horizontal, 4)
  }
}
