import SwiftUI

/// The files list's columns, shared by its head and every row so they line up: Name takes what
/// the others leave.
enum FilesColumns {
  static let size: CGFloat = 90
  static let added: CGFloat = 110
  static let goes: CGFloat = 130
  /// The Finder button's.
  static let actions: CGFloat = 32
  static let spacing: CGFloat = 8
  static let leadingInset: CGFloat = 24
  static let trailingInset: CGFloat = 20
}

/// The column heads, Ink Tertiary like every column head.
struct FilesHead: View {
  var body: some View {
    HStack(spacing: FilesColumns.spacing) {
      Text("Name").frame(maxWidth: .infinity, alignment: .leading)
      Text("Size").frame(width: FilesColumns.size, alignment: .leading)
      Text("Added").frame(width: FilesColumns.added, alignment: .leading)
      Text("Goes").frame(width: FilesColumns.goes, alignment: .leading)
      Color.clear.frame(width: FilesColumns.actions)
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
