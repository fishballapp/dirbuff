import DirBuffCore
import SwiftUI

/// What is cleared next from a folder, pushed from its page's What's Cleared Next…: every file
/// still to be cleared, in groups by when. What was already cleared is in History.
public struct FolderFilesPage: View {
  public var folder: MainFolder
  public var binName: String
  /// The folder as the shelf shows it, whose Temporary row says why a folder can't be read.
  public var folderState: FolderState?
  /// What the page's times are counted from.
  public var now: Date
  /// Set while the licence has stopped cleaning.
  public var isPaused: Bool
  /// Shows these in Finder: one file, or the folder.
  public var onShowInFinder: ([URL]) -> Void
  /// Clears a folder that can't be read: gives access back, or locates it.
  public var onFix: (Fix) -> Void
  /// Opens History with only this folder's runs.
  public var onShowHistory: () -> Void

  @State private var query = ""
  @State private var collapsedGroups: Set<UpcomingGroup.Kind> = [.later]
  @State private var openedGroups: Set<UpcomingGroup.Kind> = []

  public init(
    folder: MainFolder,
    binName: String = SystemBin.name,
    folderState: FolderState? = nil,
    now: Date = Date(),
    isPaused: Bool = false,
    onShowInFinder: @escaping ([URL]) -> Void = { _ in },
    onFix: @escaping (Fix) -> Void = { _ in },
    onShowHistory: @escaping () -> Void = {}
  ) {
    self.folder = folder
    self.binName = binName
    self.folderState = folderState
    self.now = now
    self.isPaused = isPaused
    self.onShowInFinder = onShowInFinder
    self.onFix = onFix
    self.onShowHistory = onShowHistory
  }

  private var matches: [UpcomingGroup] { folder.preview.files.matching(query) }

  public var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle(folder.name)
      .navigationSubtitle("Temporary · \(temporarySetting(folder.settings, binName: binName))")
      .toolbar {
        ToolbarItem(placement: .navigation) {
          Image(nsImage: folderIcon(atPath: folder.path))
            .resizable()
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
        }
        ToolbarItem(placement: .primaryAction) {
          ShelfSearchField(text: $query, placeholder: "Search \(folder.name)")
            .frame(width: 210)
        }
        ToolbarItem(placement: .primaryAction) {
          GhostIconButton(
            "History", systemImage: GhostIconButton.historySymbol, action: onShowHistory)
        }
        ToolbarItem(placement: .primaryAction) {
          GhostIconButton("Show in Finder", systemImage: GhostIconButton.finderSymbol) {
            onShowInFinder([URL(fileURLWithPath: folder.path)])
          }
        }
      }
  }

  @ViewBuilder
  private var content: some View {
    if let emptiness = folder.filesEmptiness(isPaused: isPaused) {
      if emptiness == .cantRead, let problem = folderState.flatMap({ FilesProblem($0, now: now) }) {
        FilesProblemView(problem: problem, folder: folder, onFix: onFix)
      } else {
        FilesEmptyView(title: emptiness.title, detail: emptiness.detail)
      }
    } else if matches.isEmpty {
      FilesEmptyView(title: "No matches", detail: "No file here has “\(query)” in its name.")
    } else {
      VStack(spacing: 0) {
        FilesHead()
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(matches) { group in groupView(group) }
          }
        }
      }
    }
  }

  /// A search shows every match, in every group.
  private func groupView(_ group: UpcomingGroup) -> some View {
    let isSearching = !query.isEmpty
    return FilesGroupView(
      group: group,
      isCollapsed: !isSearching && collapsedGroups.contains(group.kind),
      isShowingAll: isSearching || openedGroups.contains(group.kind),
      onToggleCollapsed: { collapsedGroups.formSymmetricDifference([group.kind]) },
      onShowAll: { openedGroups.insert(group.kind) },
      onShowInFinder: { onShowInFinder([$0.url]) }
    )
  }
}
