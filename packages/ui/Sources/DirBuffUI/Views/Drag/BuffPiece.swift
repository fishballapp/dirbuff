import SwiftUI

/// A buff as a piece to drag onto a folder: 36 pt, white (lighter than its ground in dark), an 8 pt
/// radius, the symbol in Accent Blue and the name in caps. It drags onto a folder, here or in
/// Finder; a click that doesn't drag calls `onClick`. A Soon piece is Quiet, with the Soon capsule,
/// and stays put.
public struct BuffPiece: View {
  let buff: Buff
  let isEnabled: Bool
  let isLifted: Bool
  let onClick: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  /// - Parameter isEnabled: Whether it can go on the folder a click adds it to; a disabled piece is
  ///   Quiet and stays put, as a Soon one does.
  public init(_ buff: Buff, isEnabled: Bool = true, onClick: @escaping () -> Void = {}) {
    self.init(buff, isEnabled: isEnabled, isLifted: false, onClick: onClick)
  }

  init(_ buff: Buff, isEnabled: Bool = true, isLifted: Bool, onClick: @escaping () -> Void = {}) {
    self.buff = buff
    self.isEnabled = isEnabled
    self.isLifted = isLifted
    self.onClick = onClick
  }

  private var isActive: Bool { buff.isAvailable && isEnabled }

  public var body: some View {
    if isActive && !isLifted {
      piece.buffDragSource(buff, onClick: onClick, onHover: { isHovered = $0 })
    } else {
      piece
    }
  }

  private var piece: some View {
    HStack(spacing: 8) {
      BuffSymbol(buff, size: .row)
        .foregroundStyle(isActive ? Palette.accentBlue : Palette.quiet)
      BuffName(buff, size: .piece)
        .foregroundStyle(isActive ? Palette.ink : Palette.inkTertiary)
      if !buff.isAvailable {
        SoonCapsule()
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
    .accessibilityAddTraits(isActive ? .isButton : [])
  }

  private var hairline: Color {
    if colorScheme == .dark { return Color.white.opacity(0.12) }
    let isRaised = isLifted || (isHovered && isActive)
    return Color.black.opacity(isRaised ? 0.2 : 0.14)
  }

  private var shadow: (color: Color, radius: CGFloat, y: CGFloat) {
    if isLifted { return (.black.opacity(0.3), 12, 8) }
    if isHovered && isActive { return (.black.opacity(0.12), 2.5, 2) }
    return (.black.opacity(colorScheme == .dark ? 0.4 : 0.08), 1, 1)
  }
}
