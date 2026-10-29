import SwiftUI

/// The "Paused" capsule on the row of a buff that does nothing. Its tooltip says why; a licence
/// pause's is a button that opens Settings' Licence section, where the user can turn every buff
/// back on.
struct PausedPill: View {
  var reason: PillReason
  var onOpenLicence: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    switch reason {
    case .paused(.licence):
      Button(action: onOpenLicence) { label }
        .buttonStyle(.plain)
        .help(reason.explanation)
        .accessibilityHint(reason.explanation)
    case .paused(.driveUnplugged), .folderMissing, .accessLost:
      label
        .help(reason.explanation)
        .accessibilityHint(reason.explanation)
    }
  }

  private var label: some View {
    Text("Paused")
      .font(.subheadline.weight(.medium))
      .foregroundStyle(Palette.inkSecondary)
      .padding(.horizontal, 9)
      .padding(.vertical, 2)
      .background(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06), in: .capsule)
      .contentShape(.capsule)
  }
}

extension PillReason {
  /// Why the buff is paused, in a sentence: the capsule's tooltip.
  public var explanation: String {
    switch self {
    case .paused(let reason): reason.explanation
    case .folderMissing: "DirBuff can't find this folder"
    case .accessLost: "macOS took away DirBuff's access to this folder"
    }
  }
}

extension PauseReason {
  /// Why the buff is paused, in a sentence.
  public var explanation: String {
    switch self {
    case .licence(.buy): "Your trial has ended. Buy DirBuff to turn every buff back on."
    case .licence(.renew):
      "Your licence doesn't cover this version. Renew it to turn every buff back on."
    case .licence(.checkNow):
      "DirBuff couldn't check your licence. Try again to turn every buff back on."
    case .driveUnplugged(let drive): "\(drive) isn't connected"
    }
  }
}
