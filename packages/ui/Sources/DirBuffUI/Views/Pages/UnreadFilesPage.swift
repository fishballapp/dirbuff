import DirBuffCore
import SwiftUI

/// Show Files, pushed from Backup's card or callout: each file the last backup of a folder couldn't
/// read, why, and **Leave Out**, which stops trying it. The rest are tried again at the next
/// backup; the folder's row clears once each is backed up or left out.
public struct UnreadFilesPage: View {
  /// Nil once the last backup read every file.
  public var state: UnreadFilesState?
  public var folderName: String
  public var folderPath: String
  public var onLeaveOut: (UnreadFile) -> Void
  /// Shows these in Finder: one file, or the folder.
  public var onShowInFinder: ([URL]) -> Void
  /// Opens the folder's versions: an unreadable file may have an earlier version that was read.
  public var onBrowseBackup: () -> Void

  public init(
    state: UnreadFilesState?,
    folderName: String,
    folderPath: String,
    onLeaveOut: @escaping (UnreadFile) -> Void = { _ in },
    onShowInFinder: @escaping ([URL]) -> Void = { _ in },
    onBrowseBackup: @escaping () -> Void = {}
  ) {
    self.state = state
    self.folderName = folderName
    self.folderPath = folderPath
    self.onLeaveOut = onLeaveOut
    self.onShowInFinder = onShowInFinder
    self.onBrowseBackup = onBrowseBackup
  }

  public var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle(folderName)
      .navigationSubtitle("Backup · \(state?.title ?? "every file backed up")")
      .toolbar {
        FolderTitleIcon(path: folderPath)
        ToolbarItem(placement: .primaryAction) {
          GhostIconButton(
            "Browse Backup", systemImage: GhostIconButton.historySymbol, action: onBrowseBackup)
        }
        ToolbarItem(placement: .primaryAction) {
          GhostIconButton("Show in Finder", systemImage: GhostIconButton.finderSymbol) {
            onShowInFinder([URL(fileURLWithPath: folderPath)])
          }
        }
      }
  }

  @ViewBuilder
  private var content: some View {
    if let state {
      VStack(alignment: .leading, spacing: 0) {
        Text(
          "Each file says why the last backup couldn't read it. Leave out the ones you don't need; the rest are tried again at the next backup."
        )
        .foregroundStyle(Palette.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.horizontal, FilesColumns.leadingInset)
        .padding(.top, 16)
        .padding(.bottom, 12)
        UnreadFilesHead()
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(Array(state.files.enumerated()), id: \.element.id) { index, file in
              UnreadFileRow(
                file: file, isStriped: index.isMultiple(of: 2),
                onLeaveOut: { onLeaveOut(file) },
                onShowInFinder: {
                  onShowInFinder([URL(fileURLWithPath: folderPath).appending(path: file.path)])
                })
            }
          }
        }
      }
    } else {
      FilesEmptyView(
        title: "Every file is backed up",
        detail: "The last backup of \(folderName) read every file it holds.")
    }
  }
}

private enum UnreadColumns {
  static let reason: CGFloat = 220
  static let leaveOut: CGFloat = 96
}

private struct UnreadFilesHead: View {
  var body: some View {
    HStack(spacing: FilesColumns.spacing) {
      Text("Name").frame(maxWidth: .infinity, alignment: .leading)
      Text("Why").frame(width: UnreadColumns.reason, alignment: .leading)
      // Leave Out and the Finder button, and the gap between them.
      Color.clear.frame(
        width: UnreadColumns.leaveOut + FilesColumns.spacing + FilesColumns.actions)
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

/// One file: its name with the folders it's in under it, why it couldn't be read, Leave Out, and
/// the Finder button.
private struct UnreadFileRow: View {
  var file: UnreadFile
  var isStriped: Bool
  var onLeaveOut: () -> Void
  var onShowInFinder: () -> Void

  var body: some View {
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
      Text(file.reason)
        .foregroundStyle(Palette.inkSecondary)
        .lineLimit(2)
        .frame(width: UnreadColumns.reason, alignment: .leading)
      Button("Leave Out", action: onLeaveOut)
        .controlSize(.small)
        .help("Stop backing up \(file.name)")
        .frame(width: UnreadColumns.leaveOut, alignment: .trailing)
      GhostIconButton(
        "Show in Finder", systemImage: GhostIconButton.finderSymbol, action: onShowInFinder
      )
      .frame(width: FilesColumns.actions, alignment: .trailing)
    }
    .font(.callout)
    .padding(.leading, FilesColumns.leadingInset)
    .padding(.trailing, FilesColumns.trailingInset)
    .padding(.vertical, 6)
    .background(isStriped ? Color.primary.opacity(0.022) : .clear)
    .accessibilityElement(children: .contain)
  }
}
