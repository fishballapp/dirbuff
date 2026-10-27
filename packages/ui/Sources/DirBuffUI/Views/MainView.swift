import AppKit
import DirBuffCore
import DirBuffKit
import SwiftUI

/// DirBuff's main window: a 228 pt sidebar of folder filters and volumes, and a `NavigationStack`
/// with the shelf of folder tiles at its root and a folder's page pushed over it.
public struct MainView: View {
  public var state: MainState
  @Binding public var selection: MainSelection
  public var binName: String
  public var onChooseFolderForBuff: (Buff) -> Void
  public var onAddBuff: (Int64, Buff) -> Void
  public var onPutBackBuff: (Int64, Buff) -> Void
  public var onFix: (Int64, Fix) -> Void
  public var onSetTemporary: (Int64, Bool) -> Void
  public var onChangeSettings: (Int64, TemporarySettings) -> Void
  public var onBuy: () -> Void
  public var onEnterKey: () -> Void
  public var onCheckLicence: () -> Void

  @State private var filter: ShelfFilter
  @State private var searchQuery: String

  public init(
    state: MainState,
    selection: Binding<MainSelection>,
    binName: String = SystemBin.name,
    initialFilter: ShelfFilter = .allFolders,
    initialSearchQuery: String = "",
    onChooseFolderForBuff: @escaping (Buff) -> Void = { _ in },
    onAddBuff: @escaping (Int64, Buff) -> Void = { _, _ in },
    onPutBackBuff: @escaping (Int64, Buff) -> Void = { _, _ in },
    onFix: @escaping (Int64, Fix) -> Void = { _, _ in },
    onSetTemporary: @escaping (Int64, Bool) -> Void = { _, _ in },
    onChangeSettings: @escaping (Int64, TemporarySettings) -> Void = { _, _ in },
    onBuy: @escaping () -> Void = {},
    onEnterKey: @escaping () -> Void = {},
    onCheckLicence: @escaping () -> Void = {}
  ) {
    self.state = state
    self._selection = selection
    self.binName = binName
    self.onChooseFolderForBuff = onChooseFolderForBuff
    self.onAddBuff = onAddBuff
    self.onPutBackBuff = onPutBackBuff
    self.onFix = onFix
    self.onSetTemporary = onSetTemporary
    self.onChangeSettings = onChangeSettings
    self.onBuy = onBuy
    self.onEnterKey = onEnterKey
    self.onCheckLicence = onCheckLicence
    self._filter = State(initialValue: initialFilter)
    self._searchQuery = State(initialValue: initialSearchQuery)
  }

  private var activeFilter: ShelfFilter {
    state.resolvedFilter(filter)
  }

  private var sidebarSelection: Binding<ShelfFilter?> {
    Binding(
      get: { activeFilter },
      set: { next in
        if let next {
          filter = next
        }
        if case .folder = selection {
          selection = .shelf
        }
      }
    )
  }

  private var pushedFolderPath: Binding<[Int64]> {
    Binding(
      get: {
        if case .folder(let id) = selection,
          state.folders.contains(where: { $0.id == id })
        {
          return [id]
        }
        return []
      },
      set: { path in
        selection = path.last.map(MainSelection.folder) ?? .shelf
      }
    )
  }

  public var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 228, ideal: 228)
    } detail: {
      NavigationStack(path: pushedFolderPath) {
        shelfPane
          .navigationDestination(for: Int64.self) { folderID in
            if let folder = state.folders.first(where: { $0.id == folderID }) {
              FolderDetailView(
                folder: folder,
                binName: binName,
                licenceRefusal: state.licenceRefusal,
                buyTitle: state.buyTitle,
                onSetTemporary: { onSetTemporary(folder.id, $0) },
                onChangeSettings: { onChangeSettings(folder.id, $0) },
                onBuy: onBuy
              )
              .navigationTitle(folder.name)
            }
          }
      }
    }
    .navigationSplitViewStyle(.balanced)
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
      TapGesture().onEnded {
        if case .folder = selection {
          selection = .shelf
        }
      }
    )
    .tag(tag)
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
          Button("Enter Licence Key…", action: onEnterKey)
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
      action: line.action.isPurchase ? onBuy : onCheckLicence
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
        Menu {
          ToolbarAddBuffMenuContent(onChooseFolder: onChooseFolderForBuff)
        } label: {
          Label("Buff", systemImage: "plus")
            .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.hidden)
        .disabled(!state.mayClean)
        .help("Add a buff to a folder")
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
            onOpen: { selection = .folder(folder.id) },
            onAddBuff: { onAddBuff(folder.id, $0) },
            onPutBackBuff: { onPutBackBuff(folder.id, $0) },
            onFix: { onFix(folder.id, $0) }
          )
        }
      }
      .padding(32)
    }
  }

  private var emptyShelf: some View {
    VStack(spacing: 12) {
      Text(
        "Add a buff with + Buff, or right-click a folder in Finder and choose Add to DirBuff…"
      )
      .foregroundStyle(Palette.inkSecondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 420)

      if state.mayClean {
        Button("Choose Folder…") {
          onChooseFolderForBuff(.temporary)
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
