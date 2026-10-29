import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One file that is still to be cleared: its icon and name, size, when it arrived and when it
/// clears, and a quiet Finder button that shows it there.
struct FileRow: View {
  var file: UpcomingFile
  var isStriped: Bool
  var onShowInFinder: () -> Void

  var body: some View {
    HStack(spacing: FilesColumns.spacing) {
      HStack(spacing: 8) {
        Image(nsImage: fileIcon(for: file.url))
          .resizable()
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
        Text(file.name)
          .foregroundStyle(Palette.ink)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Text(file.size).frame(width: FilesColumns.size, alignment: .leading)
      Text(file.added).frame(width: FilesColumns.added, alignment: .leading)
      Text(file.clears).frame(width: FilesColumns.clears, alignment: .leading)
      GhostIconButton("Show in Finder", systemImage: GhostIconButton.finderSymbol) {
        onShowInFinder()
      }
      .frame(width: FilesColumns.actions, alignment: .trailing)
    }
    .font(.callout)
    .monospacedDigit()
    .foregroundStyle(Palette.inkSecondary)
    .padding(.leading, FilesColumns.leadingInset)
    .padding(.trailing, FilesColumns.trailingInset)
    .frame(height: 26)
    .background(isStriped ? Color.primary.opacity(0.022) : .clear)
    .accessibilityElement(children: .contain)
  }
}

/// The icon for a file's kind. It asks the type, not the disk, so a long list stays quick.
private func fileIcon(for url: URL) -> NSImage {
  let type =
    url.hasDirectoryPath
    ? UTType.folder : UTType(filenameExtension: url.pathExtension) ?? .data
  return NSWorkspace.shared.icon(for: type)
}
