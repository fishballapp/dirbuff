import SwiftUI

/// A buff as a piece to drag onto a folder: 36 pt, white (lighter than its panel in dark), an 8 pt
/// radius, the symbol in Accent Blue and the name in caps. It drags onto a tile, or out onto a
/// folder in Finder. A Soon piece is Quiet, with an outlined "SOON", and stays put.
public struct BuffPiece: View {
  let buff: Buff
  let isLifted: Bool

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  public init(_ buff: Buff) {
    self.init(buff, isLifted: false)
  }

  init(_ buff: Buff, isLifted: Bool) {
    self.buff = buff
    self.isLifted = isLifted
  }

  public var body: some View {
    if buff.isAvailable && !isLifted {
      piece.buffDragSource(buff, onHover: { isHovered = $0 })
    } else {
      piece
    }
  }

  private var piece: some View {
    HStack(spacing: 8) {
      BuffSymbol(buff, size: .row)
        .foregroundStyle(buff.isAvailable ? Palette.accentBlue : Palette.quiet)
      BuffName(buff, size: .piece)
        .foregroundStyle(buff.isAvailable ? Palette.ink : Palette.inkTertiary)
      if !buff.isAvailable {
        Text("SOON")
          .font(Caps.font(size: 9.5))
          .tracking(9.5 * 0.12)
          .foregroundStyle(Palette.inkTertiary)
          .padding(.horizontal, 3)
          .padding(.top, 2)
          .padding(.bottom, 1)
          .overlay(
            RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.inkTertiary, lineWidth: 1))
      }
      Spacer(minLength: 0)
    }
    .padding(.leading, 10)
    .padding(.trailing, 14)
    .frame(height: 36)
    .background(Palette.piece, in: .rect(cornerRadius: Metrics.pieceRadius))
    .overlay(
      RoundedRectangle(cornerRadius: Metrics.pieceRadius)
        .strokeBorder(hairline, lineWidth: 0.5)
    )
    .shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    .rotationEffect(.degrees(isLifted ? -2 : 0))
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(buff.isAvailable ? buff.name : "\(buff.name), soon")
  }

  private var hairline: Color {
    if colorScheme == .dark { return Color.white.opacity(0.12) }
    let isRaised = isLifted || (isHovered && buff.isAvailable)
    return Color.black.opacity(isRaised ? 0.2 : 0.14)
  }

  private var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
    if isLifted { return (.black.opacity(0.3), 12, 8) }
    if isHovered && buff.isAvailable { return (.black.opacity(0.12), 2.5, 2) }
    return (.black.opacity(colorScheme == .dark ? 0.4 : 0.08), 1, 1)
  }
}
