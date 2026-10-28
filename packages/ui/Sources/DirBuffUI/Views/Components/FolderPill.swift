import SwiftUI

/// A folder named inside a sentence: a quiet capsule holding the folder's small icon and its name,
/// so the name reads as a folder ("Clearing [Downloads]"). Wherever DirBuff's own UI names a
/// folder in a sentence, it's one of these; system alerts, menus and notifications keep the name.
public struct FolderPill: View {
  let name: String
  let path: String

  @Environment(\.colorScheme) private var colorScheme

  public init(_ name: String, path: String) {
    self.name = name
    self.path = path
  }

  public var body: some View {
    HStack(spacing: 5) {
      Image(nsImage: folderIcon(atPath: path))
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 17, height: 14)
        .accessibilityHidden(true)
      Text(name)
        .fontWeight(.semibold)
        .foregroundStyle(Palette.ink)
        .lineLimit(1)
    }
    .padding(.leading, 5)
    .padding(.trailing, 9)
    .padding(.vertical, 2)
    .background(
      Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.065), in: .capsule
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Folder \(name)")
  }
}
