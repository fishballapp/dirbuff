import SwiftUI

/// The folder page's title pop-up opens this: every folder, needs-you first then by name, each a
/// 54 pt row of its icon and mark, its name, and the symbols of the buffs it wears. ↑↓ move,
/// Return opens, Esc closes; once the list scrolls, a filter field on top has the focus.
public struct FolderSwitcher: View {
  public var folders: [FolderState]
  public var currentID: Int64
  public var onOpen: (Int64) -> Void

  public init(folders: [FolderState], currentID: Int64, onOpen: @escaping (Int64) -> Void) {
    self.folders = folders
    self.currentID = currentID
    self.onOpen = onOpen
  }

  @State private var query = ""
  /// The row ↑↓ has moved to; nil until a key is pressed, so no row looks picked at first.
  @State private var highlightedID: Int64?
  @FocusState private var isFilterFocused: Bool
  @FocusState private var isListFocused: Bool

  /// Past this many rows the list scrolls, so it gets a filter field.
  static let rowsBeforeScrolling = 8
  private static let rowHeight: CGFloat = 54
  private static let rowGap: CGFloat = 2

  private var scrolls: Bool { folders.count > Self.rowsBeforeScrolling }

  private var visibleFolders: [FolderState] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return folders }
    return folders.filter { $0.name.localizedStandardContains(trimmed) }
  }

  public var body: some View {
    VStack(spacing: 0) {
      if scrolls {
        TextField("Filter \(folders.count) folders", text: $query)
          .textFieldStyle(.roundedBorder)
          .focused($isFilterFocused)
          .accessibilityLabel("Filter folders by name")
          .onKeyPress(.upArrow) { move(by: -1) }
          .onKeyPress(.downArrow) { move(by: 1) }
          .onKeyPress(.return) { openHighlighted() }
          .onChange(of: query) { highlightedID = visibleFolders.first?.id }
          .padding(.horizontal, 10)
          .padding(.top, 10)
          .padding(.bottom, 4)
      }
      list
      Palette.rule.frame(height: 1)
      HStack {
        (Text("↑↓").fontWeight(.semibold).foregroundStyle(Palette.inkSecondary)
          + Text(" move · ")
          + Text("↩").fontWeight(.semibold).foregroundStyle(Palette.inkSecondary)
          + Text(" open"))
        Spacer()
        (Text("⌘[").fontWeight(.semibold).foregroundStyle(Palette.inkSecondary)
          + Text(" all folders"))
      }
      .font(.caption)
      .foregroundStyle(Palette.inkTertiary)
      .padding(.horizontal, 14)
      .padding(.top, 9)
      .padding(.bottom, 11)
    }
    .frame(width: 300)
    .background(Palette.paper)
    .onAppear {
      if scrolls { isFilterFocused = true } else { isListFocused = true }
    }
  }

  private var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: Self.rowGap) {
          ForEach(visibleFolders) { folder in
            row(folder).id(folder.id)
          }
        }
        .padding(6)
      }
      .frame(height: listHeight)
      .scrollDisabled(!scrolls)
      .focusable(!scrolls)
      .focused($isListFocused)
      .focusEffectDisabled()
      .onKeyPress(.upArrow) { move(by: -1) }
      .onKeyPress(.downArrow) { move(by: 1) }
      .onKeyPress(.return) { openHighlighted() }
      .onChange(of: highlightedID) {
        guard let highlightedID else { return }
        proxy.scrollTo(highlightedID)
      }
    }
  }

  /// Every row while they fit; once they don't, as many as fit, with the list scrolling.
  private var listHeight: CGFloat {
    let rows = min(max(visibleFolders.count, 1), Self.rowsBeforeScrolling + 1)
    return CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * Self.rowGap + 12
  }

  private func row(_ folder: FolderState) -> some View {
    let isCurrent = folder.id == currentID
    let isHighlighted = folder.id == highlightedID && !isCurrent
    return Button {
      onOpen(folder.id)
    } label: {
      HStack(spacing: 11) {
        MarkedFolderIcon(path: folder.path, mark: folder.mark, size: .switcher)
          .frame(width: 38)
        VStack(alignment: .leading, spacing: 5) {
          Text(folder.name)
            .font(.system(size: 13.5, weight: isCurrent || folder.isNeedingYou ? .bold : .semibold))
            .foregroundStyle(isCurrent ? .white : Palette.ink)
            .lineLimit(1)
            .truncationMode(.tail)
          HStack(spacing: 7) {
            ForEach(folder.buffs) { row in
              BuffSymbol(row.buff, size: .switcher)
            }
          }
          .foregroundStyle(
            isCurrent
              ? Color.white.opacity(0.92)
              : folder.isNeedingYou ? Palette.amberText : Palette.inkSecondary)
        }
        Spacer(minLength: 0)
        if folder.isNeedingYou {
          NeedsYouBadge(size: 16)
        }
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 7)
      .frame(minHeight: Self.rowHeight)
      .background(background(folder, isCurrent: isCurrent, isHighlighted: isHighlighted))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isCurrent ? .isSelected : [])
  }

  @ViewBuilder
  private func background(_ folder: FolderState, isCurrent: Bool, isHighlighted: Bool)
    -> some View
  {
    let shape = RoundedRectangle(cornerRadius: Metrics.switcherRowRadius)
    if isCurrent {
      shape.fill(Palette.accentBlue)
    } else if folder.isNeedingYou {
      shape.fill(Palette.amberTint)
        .overlay(shape.strokeBorder(Palette.amber.opacity(0.24)))
        .overlay(isHighlighted ? shape.fill(Color.primary.opacity(0.05)) : nil)
    } else if isHighlighted {
      shape.fill(Color.primary.opacity(0.07))
    } else {
      shape.fill(.clear)
    }
  }

  private func move(by step: Int) -> KeyPress.Result {
    let ids = visibleFolders.map(\.id)
    guard !ids.isEmpty else { return .handled }
    let start = highlightedID ?? currentID
    let index = ids.firstIndex(of: start).map { $0 + step } ?? (step > 0 ? 0 : ids.count - 1)
    highlightedID = ids[min(max(index, 0), ids.count - 1)]
    return .handled
  }

  private func openHighlighted() -> KeyPress.Result {
    // Typing in the filter highlights its first match, so Return opens that.
    guard let id = highlightedID else { return .ignored }
    onOpen(id)
    return .handled
  }
}
