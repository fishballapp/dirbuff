import SwiftUI

/// Show Versions…, pushed from Backup's card: the files of the folder that have a past, On This
/// Mac or Deleted, and beside the list the versions of the one selected, each restorable as a
/// copy that lands beside the original with its date in the name. Nothing is replaced.
public struct VersionsPage: View {
  public var state: VersionsState
  /// The version being copied now: its row waits and Restore a Copy is off.
  public var copyingID: String?
  /// What a finished copy says; nil once dismissed.
  public var toast: VersionsToast?
  public var onRestoreCopy: (FileVersion) -> Void
  /// Restore Folder…: the dates the folder can be brought back to.
  public var onRestoreFolder: () -> Void
  /// Shows these in Finder: the folder, or the original of a file.
  public var onShowInFinder: ([URL]) -> Void
  /// Shows the copy a toast speaks of in Finder.
  public var onShowCopy: (URL) -> Void

  @State private var tab: VersionsState.Tab
  @State private var query: String
  @State private var selectedPath: String?
  @State private var selectedVersionID: String?

  public init(
    state: VersionsState,
    tab: VersionsState.Tab = .onThisMac,
    query: String = "",
    selectedPath: String? = nil,
    selectedVersionID: String? = nil,
    copyingID: String? = nil,
    toast: VersionsToast? = nil,
    onRestoreCopy: @escaping (FileVersion) -> Void = { _ in },
    onRestoreFolder: @escaping () -> Void = {},
    onShowInFinder: @escaping ([URL]) -> Void = { _ in },
    onShowCopy: @escaping (URL) -> Void = { _ in }
  ) {
    self.state = state
    self.copyingID = copyingID
    self.toast = toast
    self.onRestoreCopy = onRestoreCopy
    self.onRestoreFolder = onRestoreFolder
    self.onShowInFinder = onShowInFinder
    self.onShowCopy = onShowCopy
    self._tab = State(initialValue: tab)
    self._query = State(initialValue: query)
    self._selectedPath = State(initialValue: selectedPath)
    self._selectedVersionID = State(initialValue: selectedVersionID)
  }

  private var files: [VersionedFile] { state.files(tab, matching: query) }

  private var selectedFile: VersionedFile? {
    state.files.first { $0.path == selectedPath }
  }

  public var body: some View {
    HStack(spacing: 0) {
      list
      Palette.rule.frame(width: 1)
      VersionsInspector(
        file: selectedFile, folderName: state.folderName, selectedVersionID: $selectedVersionID,
        copyingID: copyingID, onRestoreCopy: onRestoreCopy,
        onShowOriginal: { file in
          onShowInFinder([URL(fileURLWithPath: state.folderPath).appending(path: file.path)])
        }
      )
      .frame(width: 300)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.paper)
    .overlay(alignment: .bottom) {
      if let toast {
        Toast(actionTitle: "Show in Finder") {
          onShowCopy(toast.url)
        } message: {
          Text("Restored a copy: \(toast.name)")
        }
        .padding(.bottom, 20)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeOut(duration: 0.2), value: toast)
    .navigationTitle(state.folderName)
    .navigationSubtitle(state.subtitle)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Image(nsImage: folderIcon(atPath: state.folderPath))
          .resizable()
          .frame(width: 20, height: 20)
          .accessibilityHidden(true)
      }
      ToolbarItem(placement: .principal) {
        Picker("Show", selection: $tab) {
          ForEach(VersionsState.Tab.allCases, id: \.self) { tab in
            Text(tab.title).tag(tab)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
      }
      ToolbarItem(placement: .primaryAction) {
        ShelfSearchField(text: $query, placeholder: "Search \(state.folderName)")
          .frame(width: 210)
      }
      ToolbarItem(placement: .primaryAction) {
        Button("Restore Folder…", action: onRestoreFolder)
          .help("Bring \(state.folderName) back as it was on a date, as a new folder beside it")
      }
      ToolbarItem(placement: .primaryAction) {
        GhostIconButton("Show in Finder", systemImage: GhostIconButton.finderSymbol) {
          onShowInFinder([URL(fileURLWithPath: state.folderPath)])
        }
      }
    }
    .onChange(of: tab) { selectedPath = nil }
    .onChange(of: selectedPath) { _, path in
      selectedVersionID = state.files.first { $0.path == path }.flatMap(Self.defaultVersion)?.id
    }
  }

  /// The version most likely wanted: the one before the latest, else the latest.
  static func defaultVersion(of file: VersionedFile) -> FileVersion? {
    let restorable = file.versions.filter(\.canRestore)
    return restorable.dropFirst().first ?? restorable.first
  }

  @ViewBuilder
  private var list: some View {
    if files.isEmpty {
      let words = state.emptiness(tab, query: query)
      FilesEmptyView(title: words.title, detail: words.detail)
    } else {
      VStack(spacing: 0) {
        VersionsHead()
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
              VersionedFileRow(
                file: file, isSelected: file.path == selectedPath,
                isStriped: index.isMultiple(of: 2)
              ) {
                selectedPath = file.path
              }
            }
          }
        }
      }
    }
  }
}

/// A finished copy, for the toast: its name and where it is.
public struct VersionsToast: Sendable, Equatable, Identifiable {
  public let id = UUID()
  public var name: String
  public var url: URL

  public init(url: URL) {
    self.url = url
    name = url.lastPathComponent
  }
}

private enum VersionsColumns {
  static let changed: CGFloat = 150
  static let size: CGFloat = 80
  static let versions: CGFloat = 76
}

private struct VersionsHead: View {
  var body: some View {
    HStack(spacing: FilesColumns.spacing) {
      Text("Name").frame(maxWidth: .infinity, alignment: .leading)
      Text("Changed").frame(width: VersionsColumns.changed, alignment: .leading)
      Text("Size").frame(width: VersionsColumns.size, alignment: .leading)
      Text("Versions").frame(width: VersionsColumns.versions, alignment: .trailing)
    }
    .font(.subheadline)
    .foregroundStyle(Palette.inkTertiary)
    .padding(.leading, FilesColumns.leadingInset)
    .padding(.trailing, FilesColumns.trailingInset)
    .frame(height: 28)
    .overlay(alignment: .bottom) { Palette.rule.frame(height: 1) }
    .accessibilityHidden(true)
  }
}

private struct VersionedFileRow: View {
  var file: VersionedFile
  var isSelected: Bool
  var isStriped: Bool
  var onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: FilesColumns.spacing) {
        VStack(alignment: .leading, spacing: 1) {
          Text(file.name)
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .truncationMode(.middle)
          if !file.parent.isEmpty {
            Text(file.parent)
              .font(.subheadline)
              .foregroundStyle(Palette.inkTertiary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(file.changed)
          .foregroundStyle(Palette.inkSecondary)
          .frame(width: VersionsColumns.changed, alignment: .leading)
        Text(file.size)
          .foregroundStyle(Palette.inkSecondary)
          .frame(width: VersionsColumns.size, alignment: .leading)
        Text("\(file.restorableCount)")
          .foregroundStyle(Palette.inkSecondary)
          .frame(width: VersionsColumns.versions, alignment: .trailing)
      }
      .font(.callout)
      .monospacedDigit()
      .padding(.leading, FilesColumns.leadingInset)
      .padding(.trailing, FilesColumns.trailingInset)
      .padding(.vertical, 6)
      .background(
        isSelected
          ? Palette.blueTint : (isStriped ? Color.primary.opacity(0.022) : Color.clear)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// The selected file's past, beside the list.
private struct VersionsInspector: View {
  var file: VersionedFile?
  var folderName: String
  @Binding var selectedVersionID: String?
  var copyingID: String?
  var onRestoreCopy: (FileVersion) -> Void
  var onShowOriginal: (VersionedFile) -> Void

  private var selected: FileVersion? {
    file?.versions.first { $0.id == selectedVersionID }
  }

  var body: some View {
    if let file {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 2) {
          Text(file.name)
            .font(.headline)
            .foregroundStyle(Palette.ink)
            .lineLimit(2)
            .truncationMode(.middle)
          Text(
            [file.parent.isEmpty ? folderName : file.parent, file.size, file.versionCount]
              .filter { $0 != "—" }.joined(separator: " · ")
          )
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
          .lineLimit(1)
          .truncationMode(.middle)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)

        ScrollView {
          VStack(spacing: 0) {
            ForEach(file.versions) { version in
              VersionRow(
                version: version, isSelected: version.id == selectedVersionID
              ) {
                if version.canRestore { selectedVersionID = version.id }
              }
            }
            if file.hasEarlierVersionNotKept {
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: "minus.circle")
                  .foregroundStyle(Palette.quiet)
                  .padding(.top, 1)
                  .accessibilityHidden(true)
                Text(VersionedFile.earlierNotKept)
                  .font(.subheadline)
                  .foregroundStyle(Palette.inkTertiary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(.horizontal, 18)
              .padding(.vertical, 6)
            }
          }
        }
        .frame(maxHeight: 260)

        HStack(spacing: 8) {
          Button("Restore a Copy") {
            if let selected { onRestoreCopy(selected) }
          }
          .buttonStyle(.borderedProminent)
          .tint(Palette.accentBlue)
          .disabled(selected?.canRestore != true || copyingID != nil)
          if !file.isDeleted {
            Button("Show Original") { onShowOriginal(file) }
          }
          if copyingID != nil {
            ProgressView().controlSize(.small)
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)

        Text(sentence(file))
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 18)
        Spacer(minLength: 0)
      }
      .frame(maxHeight: .infinity, alignment: .top)
    } else {
      VStack(spacing: 6) {
        Text("Select a file")
          .font(.headline)
          .foregroundStyle(Palette.ink)
        Text("Its versions are listed here, and any of them can be restored as a copy.")
          .foregroundStyle(Palette.inkSecondary)
      }
      .multilineTextAlignment(.center)
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func sentence(_ file: VersionedFile) -> String {
    guard let selected else {
      return "Choose a version. A deletion holds no file, so it can't be restored."
    }
    return
      "Puts the \(selected.when) version beside \(file.isDeleted ? "where it was" : "the original"), with its date in the name. Nothing is replaced."
  }
}

private struct VersionRow: View {
  var version: FileVersion
  var isSelected: Bool
  var onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: 10) {
        Image(
          systemName: !version.canRestore
            ? "minus.circle" : (isSelected ? "largecircle.fill.circle" : "circle")
        )
        .foregroundStyle(isSelected ? Palette.accentBlue : Palette.quiet)
        .padding(.top, 1)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(version.when)
            .foregroundStyle(version.canRestore ? Palette.ink : Palette.inkTertiary)
          Text(version.detail)
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
        }
        Spacer(minLength: 0)
      }
      .monospacedDigit()
      .padding(.horizontal, 18)
      .padding(.vertical, 6)
      .background(isSelected ? Palette.blueTint : .clear)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
