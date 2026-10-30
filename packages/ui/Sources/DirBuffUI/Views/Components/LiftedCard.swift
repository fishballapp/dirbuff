import SwiftUI

extension View {
  /// A card on the window's ground, lifted like a tile: History's list, a run's files, a buff on
  /// the Buffs page.
  func liftedCard() -> some View {
    modifier(LiftedCard())
  }
}

private struct LiftedCard: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .background(Palette.card)
      .clipShape(.rect(cornerRadius: Metrics.tileRadius))
      .overlay {
        RoundedRectangle(cornerRadius: Metrics.tileRadius)
          .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.14), lineWidth: 0.5)
      }
      .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.07), radius: 8, x: 0, y: 3)
  }
}
