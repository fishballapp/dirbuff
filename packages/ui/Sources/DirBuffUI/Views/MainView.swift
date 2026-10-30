import AppKit
import DirBuffCore
import DirBuffKit
import SwiftUI

/// DirBuff's main window: a 228 pt sidebar of All Folders, Buffs, History and a row per folder, and
/// a `NavigationStack` with the selected row's page at its root and pages pushed over it. History,
/// a folder's page and the pushed pages are built by the app, each in its own file.
public struct MainView: View {
  public var state: MainState
  @Binding public var navigation: MainNavigation
  public var actions: ShelfActions
  public var folderPage: (Int64) -> AnyView
  public var history: () -> AnyView
  public var page: (MainPage) -> AnyView

  @State private var searchQuery: String

  public init(
    state: MainState,
    navigation: Binding<MainNavigation>,
    actions: ShelfActions = ShelfActions(),
    initialSearchQuery: String = "",
    folderPage: @escaping (Int64) -> AnyView = { _ in AnyView(EmptyView()) },
    history: @escaping () -> AnyView = { AnyView(EmptyView()) },
    page: @escaping (MainPage) -> AnyView = { _ in AnyView(EmptyView()) }
  ) {
    self.state = state
    self._navigation = navigation
    self.actions = actions
    self.folderPage = folderPage
    self.history = history
    self.page = page
    self._searchQuery = State(initialValue: initialSearchQuery)
  }

  public var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 228, ideal: 228)
    } detail: {
      NavigationStack(path: $navigation.path) {
        root
          .id(navigation.place)
          .navigationDestination(for: MainPage.self, destination: page)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .onChange(of: state.folders.map(\.id)) { _, ids in
      let kept = navigation.keeping(folders: Set(ids))
      if kept != navigation { navigation = kept }
    }
  }

  @ViewBuilder
  private var root: some View {
    switch navigation.place {
    case .allFolders: shelfPane
    case .buffs:
      BuffsPage(
        state: state.buffsPage(), actions: actions,
        onOpenFolder: { navigation = MainNavigation(.folder($0)) })
    case .history: history()
    case .folder(let id): folderPage(id)
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    List(selection: $navigation.selection) {
      Section {
        placeRow("All Folders", systemImage: "folder", count: state.shelfFolders.count)
          .tag(SidebarPlace.allFolders)
        placeRow("Buffs", systemImage: "dumbbell")
          .tag(SidebarPlace.buffs)
        placeRow("History", systemImage: "clock.arrow.circlepath")
          .tag(SidebarPlace.history)
      }

      Section {
        ForEach(state.sidebarFolders) { row in
          SidebarFolderRow(
            row: row,
            addBuffItems: state.addBuffItems(for: row.folder),
            mayClean: state.mayClean,
            onAddBuff: { actions.add($0, to: row.id) }
          )
          .tag(SidebarPlace.folder(row.id))
        }
      } header: {
        HStack {
          Text("Folders")
          Spacer(minLength: 4)
          Button(action: actions.addFolder) {
            Image(systemName: "plus")
              .font(.system(size: 12, weight: .medium))
          }
          .buttonStyle(.borderless)
          .help("Add Folder…")
          .accessibilityLabel("Add Folder…")
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let line = state.licenceLine {
        licenceFoot(line)
      }
    }
  }

  private func placeRow(_ title: String, systemImage: String, count: Int? = nil) -> some View {
    HStack(spacing: 8) {
      Image(systemName: systemImage)
        .foregroundStyle(Palette.accentBlue)
        .frame(width: 18, height: 16, alignment: .center)
        .accessibilityHidden(true)
      Text(title)
        .lineLimit(1)
      Spacer(minLength: 4)
      if let count {
        Text("\(count)")
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
  }

  /// The licence line and its action side by side while they fit, with Enter Licence Key… beneath.
  private func licenceFoot(_ line: LicenceLine) -> some View {
    let text = VStack(alignment: .leading, spacing: 1) {
      Text(line.text)
        .fontWeight(.semibold)
      if let detail = licenceDetail(line) {
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
      }
    }
    let button = licenceButton(line)
    return VStack(spacing: 0) {
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            text.fixedSize()
            Spacer(minLength: 0)
            button.fixedSize()
          }
          VStack(alignment: .leading, spacing: 8) {
            text
            button
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        if line.action.isPurchase {
          Button("Enter Licence Key…", action: actions.enterKey)
            .buttonStyle(.link)
            .foregroundStyle(Palette.accentBlue)
        }
      }
      .font(.callout)
      .monospacedDigit()
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
    }
  }

  private func licenceDetail(_ line: LicenceLine) -> String? {
    if !state.mayClean { return "Every buff is paused" }
    return line.action == .buy ? "then $10 a year" : nil
  }

  @ViewBuilder
  private func licenceButton(_ line: LicenceLine) -> some View {
    let button = Button(
      line.action.shortTitle,
      action: line.action.isPurchase ? actions.buy : actions.checkLicence
    )
    if state.mayClean {
      button
    } else {
      button
        .buttonStyle(.borderedProminent)
        .tint(Palette.accentBlue)
    }
  }

  // MARK: - All Folders

  private var visibleFolders: [FolderState] {
    state.shelfFolders(matching: searchQuery)
  }

  private var shelfPane: some View {
    Group {
      if state.shelfFolders.isEmpty {
        emptyShelf
      } else if visibleFolders.isEmpty {
        emptyFilterResult
      } else {
        shelfGrid
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.paper)
    .navigationTitle("All Folders")
    .navigationSubtitle(state.shelfSubtitle)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button(action: actions.addFolder) {
          Label("Folder", systemImage: "plus")
            .labelStyle(.titleAndIcon)
        }
        .help("Add Folder…")
      }

      ToolbarItem(placement: .primaryAction) {
        ShelfSearchField(text: $searchQuery)
          .frame(width: 210)
      }
    }
  }

  private var shelfGrid: some View {
    ScrollView {
      LazyVGrid(
        columns: [
          GridItem(.adaptive(minimum: 260, maximum: .infinity), spacing: 20, alignment: .top)
        ],
        alignment: .leading,
        spacing: 24
      ) {
        ForEach(visibleFolders) { folder in
          FolderTileView(
            folder: folder,
            addBuffItems: state.addBuffItems(for: folder),
            canAddBuff: state.mayClean,
            actions: actions,
            onOpen: { navigation = MainNavigation(.folder(folder.id)) }
          )
        }
      }
      .padding(32)
    }
  }

  private var emptyShelf: some View {
    VStack(spacing: 12) {
      Text("Add a folder, or right-click one in Finder and choose DirBuff: Add Buff.")
        .foregroundStyle(Palette.inkSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 480)

      Button("Add Folder…", action: actions.addFolder)
    }
    .padding(32)
  }

  private var emptyFilterResult: some View {
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return VStack(spacing: 10) {
      Text("No folders matching “\(trimmed)”")
        .font(.headline)
        .foregroundStyle(Palette.ink)
      Button("Clear Filter") {
        searchQuery = ""
      }
      .controlSize(.small)
    }
    .padding(32)
  }
}

extension LicenceLine.Action {
  /// The sidebar foot's button, short enough to sit beside the trial or paused line.
  fileprivate var shortTitle: String {
    switch self {
    case .buy: "Buy…"
    case .renew: "Renew…"
    case .checkNow: title
    }
  }
}
