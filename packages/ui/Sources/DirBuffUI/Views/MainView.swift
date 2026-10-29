import AppKit
import DirBuffCore
import DirBuffKit
import SwiftUI

/// DirBuff's main window: a 228 pt sidebar of folder filters, History and volumes, and a
/// `NavigationStack` with the shelf of folder tiles (or History's runs) at its root and pages
/// pushed over it. Each page is built by the app through `destination`, in its own file.
public struct MainView: View {
  public var state: MainState
  @Binding public var navigation: MainNavigation
  public var actions: ShelfActions
  public var destination: (MainRoute) -> AnyView

  @State private var filter: ShelfFilter
  @State private var searchQuery: String
  /// The folder last opened, selected on the shelf when it comes back: + Buff's click adds to it.
  @State private var selectedFolderID: Int64?

  public init(
    state: MainState,
    navigation: Binding<MainNavigation>,
    actions: ShelfActions = ShelfActions(),
    initialFilter: ShelfFilter = .allFolders,
    initialSearchQuery: String = "",
    initialSelectedFolderID: Int64? = nil,
    destination: @escaping (MainRoute) -> AnyView = { _ in AnyView(EmptyView()) }
  ) {
    self.state = state
    self._navigation = navigation
    self.actions = actions
    self.destination = destination
    self._filter = State(initialValue: initialFilter)
    self._searchQuery = State(initialValue: initialSearchQuery)
    self._selectedFolderID = State(initialValue: initialSelectedFolderID)
  }

  private var activeFilter: ShelfFilter {
    state.resolvedFilter(filter)
  }

  /// The sidebar's row: a shelf filter, or History. Choosing one pops every page.
  private var sidebarSelection: Binding<SidebarItem?> {
    Binding(
      get: { navigation.root == .history ? .history : .filter(activeFilter) },
      set: { next in
        switch next {
        case .history: navigation = MainNavigation(root: .history)
        case .filter(let next):
          filter = next
          navigation = MainNavigation(root: .shelf)
        case nil: break
        }
      }
    )
  }

  public var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 228, ideal: 228)
    } detail: {
      NavigationStack(path: $navigation.path) {
        root
          .navigationDestination(for: MainRoute.self, destination: destination)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .onChange(of: state.folders.map(\.id)) { _, ids in
      let kept = navigation.keeping(folders: Set(ids))
      if kept != navigation { navigation = kept }
    }
    // However a folder's page opened (a tile, the switcher, Finder, a notification).
    .onChange(of: navigation.path, initial: true) {
      if let opened = navigation.path.compactMap(\.folderID).last {
        selectedFolderID = opened
      }
    }
  }

  @ViewBuilder
  private var root: some View {
    switch navigation.root {
    case .shelf: shelfPane
    case .history: destination(.history(folderID: nil))
    }
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    List(selection: sidebarSelection) {
      Section("Folders") {
        sidebarRow(
          title: "All Folders",
          count: state.shelfFolders.count,
          tag: .allFolders
        ) {
          Image(systemName: "folder")
            .foregroundStyle(Palette.accentBlue)
        }

        if state.showsNeedsYouInSidebar {
          sidebarRow(
            title: "Needs You",
            count: state.needsYouCount,
            tag: .needsYou
          ) {
            Image(systemName: "exclamationmark.circle")
              .foregroundStyle(Palette.amber)
          }
        }

        ForEach(state.sidebarBuffs, id: \.self) { buff in
          sidebarRow(
            title: buff.name,
            count: state.buffCount(buff),
            tag: .buff(buff)
          ) {
            BuffSymbol(buff, size: .sidebar)
              .foregroundStyle(Palette.accentBlue)
          }
        }

        HStack(spacing: 8) {
          Image(systemName: "clock.arrow.circlepath")
            .foregroundStyle(Palette.accentBlue)
            .frame(width: 18, height: 16, alignment: .center)
            .accessibilityHidden(true)
          Text("History")
        }
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded { navigation.path = [] })
        .tag(SidebarItem.history)
      }

      if !state.locations.isEmpty {
        Section("Locations") {
          ForEach(state.locations) { location in
            sidebarRow(
              title: location.name,
              count: location.count,
              tag: .location(location.volumePath)
            ) {
              Image(systemName: location.isExternal ? "externaldrive" : "internaldrive")
                .foregroundStyle(Palette.accentBlue)
            }
          }
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let line = state.licenceLine {
        licenceFoot(line)
      }
    }
  }

  private func sidebarRow<Icon: View>(
    title: String,
    count: Int,
    tag: ShelfFilter,
    @ViewBuilder icon: () -> Icon
  ) -> some View {
    HStack(spacing: 8) {
      icon()
        .frame(width: 18, height: 16, alignment: .center)
        .accessibilityHidden(true)
      Text(title)
        .lineLimit(1)
      Spacer(minLength: 4)
      Text("\(count)")
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .contentShape(.rect)
    .simultaneousGesture(
      // Choosing the row already shown still goes back to it from a pushed page.
      TapGesture().onEnded { navigation.path = [] }
    )
    .tag(SidebarItem.filter(tag))
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

  // MARK: - Shelf

  private var visibleFolders: [FolderState] {
    state.shelfFolders(matching: activeFilter, query: searchQuery)
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
    .navigationTitle(state.toolbarTitle(for: activeFilter))
    .navigationSubtitle(state.toolbarSubtitle(for: activeFilter))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        AddBuffButton(
          target: state.shelfFolders.first { $0.id == selectedFolderID }.map(state.addBuffTarget),
          isEnabled: state.mayClean,
          actions: actions)
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
            isSelected: folder.id == selectedFolderID,
            actions: actions,
            onOpen: { navigation.path = [.folder(folder.id)] }
          )
        }
      }
      .padding(32)
    }
  }

  private var emptyShelf: some View {
    VStack(spacing: 12) {
      Text(
        "Add a buff with + Buff, or right-click a folder in Finder and choose DirBuff: Add Buff"
      )
      .foregroundStyle(Palette.inkSecondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 420)

      if state.mayClean {
        Button("Choose Folder…") {
          actions.chooseFolderForBuff(.temporary)
        }
      }
    }
    .padding(32)
  }

  private var emptyFilterResult: some View {
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    return VStack(spacing: 10) {
      if !trimmed.isEmpty {
        Text("No folders matching “\(trimmed)”")
          .font(.headline)
          .foregroundStyle(Palette.ink)
        Button("Clear Filter") {
          searchQuery = ""
        }
        .controlSize(.small)
      } else if activeFilter == .needsYou {
        Text("Nothing needs you")
          .font(.headline)
          .foregroundStyle(Palette.inkSecondary)
      } else {
        Text("No folders")
          .font(.headline)
          .foregroundStyle(Palette.inkSecondary)
      }
    }
    .padding(32)
  }
}

/// A row in the sidebar.
private enum SidebarItem: Hashable {
  case filter(ShelfFilter)
  case history
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

extension MainRoute {
  /// The folder whose page this is.
  fileprivate var folderID: Int64? {
    if case .folder(let id) = self { return id }
    return nil
  }
}
