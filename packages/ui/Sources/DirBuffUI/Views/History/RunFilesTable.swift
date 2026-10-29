import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A run's files under Name, Size and Status, in one group per folder that collapses. A folder's ghost
/// icons line up with its files'. A long group shows a few files, then "and 3 more".
struct RunFilesTable: View {
  var groups: [RunFolderGroup]
  var actions: RunActions

  @State private var collapsed: Set<Int64> = []
  @State private var expanded: Set<Int64> = []

  var body: some View {
    VStack(spacing: 0) {
      columns(
        Text("Name"), Text("Size"), Text("Status"), Color.clear.frame(height: 1)
      )
      .font(.subheadline)
      .foregroundStyle(Palette.inkTertiary)
      .frame(height: 28)
      Palette.rule.frame(height: 1)
      ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
        if index > 0 {
          Palette.rule.frame(height: 1)
        }
        header(group)
        Palette.rule.frame(height: 1)
        if !collapsed.contains(group.id) {
          let isExpanded = expanded.contains(group.id)
          ForEach(Array(group.shownFiles(isExpanded: isExpanded).enumerated()), id: \.element.id) {
            index, file in
            row(file)
              .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.022))
          }
          if let more = group.more(isExpanded: isExpanded) {
            Button(more) { expanded.insert(group.id) }
              .buttonStyle(.plain)
              .font(.callout)
              .foregroundStyle(Palette.inkTertiary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.leading, 46)
              .padding(.top, 5)
              .padding(.bottom, 9)
          }
        }
      }
    }
    .font(.callout)
  }

  /// The four columns every row shares: a flexible name, then fixed size, status and actions.
  private func columns(
    _ name: some View, _ size: some View, _ status: some View, _ buttons: some View
  ) -> some View {
    HStack(spacing: 8) {
      name.frame(maxWidth: .infinity, alignment: .leading)
      size.frame(width: 80, alignment: .leading)
      status.frame(width: 170, alignment: .leading)
      buttons.frame(width: 60, alignment: .trailing)
    }
    .padding(.leading, 20)
    .padding(.trailing, 12)
  }

  private func header(_ group: RunFolderGroup) -> some View {
    let isCollapsed = collapsed.contains(group.id)
    return HStack(spacing: 9) {
      Button {
        if isCollapsed {
          collapsed.remove(group.id)
        } else {
          collapsed.insert(group.id)
        }
      } label: {
        HStack(spacing: 9) {
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Palette.quiet)
            .rotationEffect(.degrees(isCollapsed ? -90 : 0))
            .frame(width: 12)
          RunFolderIcon(folder: group.folder)
          Text(group.folder.name)
            .fontWeight(.semibold)
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
          Text(group.summary)
            .foregroundStyle(Palette.inkTertiary)
            .monospacedDigit()
            .lineLimit(1)
        }
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(isCollapsed ? "Show \(group.folder.name)" : "Hide \(group.folder.name)")
      Spacer(minLength: 0)
      HStack(spacing: 2) {
        if !group.putBackEntryIDs.isEmpty {
          GhostIconButton("Put Back All", systemImage: GhostIconButton.putBackSymbol) {
            actions.putBack(group.putBackEntryIDs)
          }
        }
        GhostIconButton("Show in Finder", systemImage: GhostIconButton.finderSymbol) {
          actions.openFolder(group.folder.path)
        }
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, 12)
    .frame(height: 40)
    .background(Palette.well)
  }

  private func row(_ file: RunFile) -> some View {
    let tone = file.isInBin ? Palette.inkSecondary : Palette.inkTertiary
    return columns(
      HStack(spacing: 8) {
        Image(nsImage: fileIcon(file))
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 16, height: 20)
          .opacity(file.isInBin ? 1 : 0.55)
          .accessibilityHidden(true)
        Text(file.name)
          .foregroundStyle(file.isInBin ? Palette.ink : Palette.inkTertiary)
          .lineLimit(1)
          .truncationMode(.middle)
      },
      Text(file.size).foregroundStyle(tone).monospacedDigit(),
      Text(file.status).foregroundStyle(tone).monospacedDigit().lineLimit(1),
      HStack(spacing: 2) {
        if let binnedPath = file.binnedPath {
          GhostIconButton("Put Back", systemImage: GhostIconButton.putBackSymbol) {
            actions.putBack([file.id])
          }
          GhostIconButton("Show in Finder", systemImage: GhostIconButton.finderSymbol) {
            actions.showInBin(binnedPath)
          }
        }
      }
    )
    .frame(height: 26)
  }

  /// The item's own icon while it's in the Bin; otherwise its kind's, from its name.
  private func fileIcon(_ file: RunFile) -> NSImage {
    if let binnedPath = file.binnedPath {
      return NSWorkspace.shared.icon(forFile: binnedPath)
    }
    let type = UTType(filenameExtension: URL(fileURLWithPath: file.name).pathExtension)
    return NSWorkspace.shared.icon(for: type ?? .data)
  }
}

/// A folder's 20 pt Finder icon with its mark at the lower left.
private struct RunFolderIcon: View {
  var folder: HistoryFolder

  var body: some View {
    Image(nsImage: folderIcon(atPath: folder.path))
      .resizable()
      .interpolation(.high)
      .frame(width: 20, height: 20)
      .overlay(alignment: .bottomLeading) {
        if let mark = folder.mark {
          Mark(mark, size: 12)
            .offset(x: -2, y: 2)
        }
      }
      .accessibilityHidden(true)
  }
}
