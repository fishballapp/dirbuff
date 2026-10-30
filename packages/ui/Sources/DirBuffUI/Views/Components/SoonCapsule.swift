import SwiftUI

/// "Soon" beside a buff this build can't put on a folder yet: a plain capsule in the system font,
/// like the Paused capsule, since the caps face is for buff names only.
struct SoonCapsule: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Text("Soon")
      .font(.subheadline.weight(.medium))
      .foregroundStyle(Palette.inkSecondary)
      .padding(.horizontal, 9)
      .padding(.vertical, 2)
      .background(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.065), in: .capsule)
  }
}
