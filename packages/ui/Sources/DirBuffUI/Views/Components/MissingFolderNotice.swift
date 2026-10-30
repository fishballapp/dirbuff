import SwiftUI

/// What a folder that wears nothing says once DirBuff can't find it, on its tile and its page:
/// "Can't find [Scratch]", with Locate… and Remove from DirBuff…. A folder that wears a buff says
/// it on the buff's row instead.
struct MissingFolderNotice: View {
  var folder: FolderState
  var actions: ShelfActions

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 5) {
        Text("Can't find")
        FolderPill(folder.name, path: folder.path)
      }
      .font(.body.weight(.semibold))
      .foregroundStyle(Palette.amberText)
      Text("It may have been deleted or moved.")
        .font(.subheadline)
        .foregroundStyle(Palette.inkSecondary)
      HStack(spacing: 8) {
        Button(Fix.locate.title) { actions.locate(folder.id) }
          .buttonStyle(.borderedProminent)
          .tint(Palette.accentBlue)
        Button("Remove from DirBuff…") { actions.removeFolder(folder.id) }
      }
      .controlSize(.small)
      .padding(.top, 4)
    }
    .multilineTextAlignment(.center)
  }
}
