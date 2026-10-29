import SwiftUI

/// A near-black bar at the foot of a window that says what just changed and offers one button,
/// such as **Undo**. Its content draws as on a dark ground in either appearance, so a folder pill
/// inside it stays light on dark.
public struct Toast<Message: View>: View {
  let actionTitle: String
  let action: () -> Void
  let message: Message

  public init(
    actionTitle: String, action: @escaping () -> Void, @ViewBuilder message: () -> Message
  ) {
    self.actionTitle = actionTitle
    self.action = action
    self.message = message()
  }

  public var body: some View {
    HStack(spacing: 12) {
      message
        .font(.callout)
        .foregroundStyle(Color(white: 0.957))
        .monospacedDigit()
        .lineLimit(1)
      Button(action: action) {
        Text(actionTitle)
          .font(.callout.weight(.medium))
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .frame(height: 24)
          .background(.white.opacity(0.14), in: .rect(cornerRadius: 7))
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
    }
    .padding(.vertical, 8)
    .padding(.leading, 14)
    .padding(.trailing, 8)
    .background(Palette.toast, in: .rect(cornerRadius: Metrics.toastRadius))
    .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .contain)
  }
}
