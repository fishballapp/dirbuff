import SwiftUI

/// A buffed folder's one state, shown by the 💪 mark in Finder, on DirBuff's folder icons and,
/// across every folder, by the menu-bar glyph. Ordered by urgency: the most urgent wins.
public enum MarkState: Int, Comparable, CaseIterable, Sendable {
  case atRest
  case paused
  case working
  case needsYou

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The 💪 mark on a 40 × 40 grid, scaled to `size`. A coloured image, the same in light and dark,
/// told apart by shape: a white disc at rest, a blue arc on its rim and a smaller arm while
/// working, an amber "!" at its lower right when it needs the user, a grey ring when paused.
public struct Mark: View {
  let state: MarkState
  let size: CGFloat

  public init(_ state: MarkState, size: CGFloat) {
    self.state = state
    self.size = size
  }

  public var body: some View {
    Canvas { context, canvas in
      let unit = canvas.width / 40
      func rect(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat) -> CGRect {
        CGRect(x: x * unit, y: y * unit, width: side * unit, height: side * unit)
      }
      func disc(radius: CGFloat) -> Path {
        Path(ellipseIn: rect(20 - radius, 20 - radius, radius * 2))
      }

      switch state {
      case .paused:
        context.fill(disc(radius: 17.6), with: .color(.white.opacity(0.55)))
        context.stroke(disc(radius: 17.6), with: .color(Self.grey), lineWidth: 2 * unit)
        context.fill(Arm().path(in: rect(7, 6.5, 26)), with: .color(Self.grey))
      case .atRest, .working, .needsYou:
        context.fill(disc(radius: 18.5), with: .color(.white))
        context.stroke(disc(radius: 18.5), with: .color(.black.opacity(0.2)), lineWidth: unit)
        if state == .working {
          var arc = Path()
          // 64 of the rim's 101.8 units, clockwise from the top.
          arc.addArc(
            center: CGPoint(x: 20 * unit, y: 20 * unit), radius: 16.2 * unit,
            startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * 64 / 101.8),
            clockwise: false)
          context.stroke(
            arc, with: .color(Self.blue),
            style: StrokeStyle(lineWidth: 3.6 * unit, lineCap: .round))
          context.fill(Arm().path(in: rect(9, 8.5, 22)), with: .color(Self.ink))
        } else {
          context.fill(Arm().path(in: rect(7, 6.5, 26)), with: .color(Self.ink))
        }
        if state == .needsYou {
          NeedsYouBadge.draw(in: context, rect: rect(20.4, 20.4, 19.2), color: Self.amber)
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  // Fixed, not the palette's light and dark pairs: the mark looks the same in both.
  private static let ink = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255)
  private static let blue = Color(red: 0x2B / 255, green: 0x4B / 255, blue: 0xD8 / 255)
  private static let amber = Color(red: 0xC9 / 255, green: 0x8B / 255, blue: 0)
  private static let grey = Color(red: 0x9A / 255, green: 0x9A / 255, blue: 0x95 / 255)
}

/// The needs-you badge: a filled Amber disc with a white "!", no border. 16 pt wherever DirBuff
/// draws it small: a buff row's symbol, a switcher row's end, the popover's callout.
public struct NeedsYouBadge: View {
  let size: CGFloat

  public init(size: CGFloat = 16) {
    self.size = size
  }

  public var body: some View {
    Canvas { context, canvas in
      Self.draw(in: context, rect: CGRect(origin: .zero, size: canvas), color: Palette.amber)
    }
    .frame(width: size, height: size)
    .accessibilityLabel("Needs you")
  }

  /// Draws the badge, from its 20 × 20 grid, into `rect`.
  static func draw(in context: GraphicsContext, rect: CGRect, color: Color) {
    let unit = rect.width / 20
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
    }
    context.fill(Path(ellipseIn: rect), with: .color(color))
    var stem = Path()
    stem.move(to: point(10, 4.6))
    stem.addLine(to: point(10, 11.2))
    context.stroke(
      stem, with: .color(.white), style: StrokeStyle(lineWidth: 2.6 * unit, lineCap: .round))
    let dot = point(10, 15)
    let dotRadius = 1.55 * unit
    let dotRect = CGRect(
      x: dot.x - dotRadius, y: dot.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
    context.fill(Path(ellipseIn: dotRect), with: .color(.white))
  }
}
