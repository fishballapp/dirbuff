import SwiftUI

/// A group of files cleared together, on a Well band that collapses. A long group shows a few
/// files, then "and 8 more", which opens the rest.
struct FilesGroupView: View {
  /// Files a long group shows before "and N more".
  static let visibleFileCount = 4

  var group: UpcomingGroup
  var isCollapsed: Bool
  var isShowingAll: Bool
  var onToggleCollapsed: () -> Void
  var onShowAll: () -> Void
  var onShowInFinder: (UpcomingFile) -> Void

  /// One hidden file would take a row to say so, so a group only hides two or more.
  private var hiddenCount: Int {
    let extra = group.files.count - Self.visibleFileCount
    return isShowingAll || extra < 2 ? 0 : extra
  }

  private var visibleFiles: ArraySlice<UpcomingFile> {
    group.files.prefix(group.files.count - hiddenCount)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      if !isCollapsed {
        ForEach(Array(visibleFiles.enumerated()), id: \.element.id) { index, file in
          FileRow(
            file: file, isStriped: !index.isMultiple(of: 2),
            onShowInFinder: { onShowInFinder(file) })
        }
        if hiddenCount > 0 {
          Button(action: onShowAll) {
            Text("and \(hiddenCount) more")
              .font(.callout)
              .foregroundStyle(Palette.inkTertiary)
              .padding(.leading, 46)
              .padding(.trailing, FilesColumns.trailingInset)
              .padding(.top, 5)
              .padding(.bottom, 9)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(.rect)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var header: some View {
    Button(action: onToggleCollapsed) {
      HStack(spacing: 8) {
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(Palette.quiet)
          .rotationEffect(isCollapsed ? .degrees(-90) : .zero)
          .frame(width: 14)
          .accessibilityHidden(true)
        Text(group.title).fontWeight(.semibold).foregroundStyle(Palette.ink)
        Text(group.summary).font(.callout).foregroundStyle(Palette.inkTertiary)
        Spacer()
      }
      .monospacedDigit()
      .padding(.leading, 10)
      .padding(.trailing, FilesColumns.trailingInset)
      .frame(height: 34)
      .background(Palette.well)
      .overlay(alignment: .top) { Palette.rule.frame(height: 1) }
      .overlay(alignment: .bottom) { Palette.rule.frame(height: 1) }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(group.title), \(group.summary)")
    .accessibilityHint(isCollapsed ? "Expands the group" : "Collapses the group")
  }
}
