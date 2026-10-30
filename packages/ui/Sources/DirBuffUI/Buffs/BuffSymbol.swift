import SwiftUI

/// A buff's plain line symbol: one stroke weight, round caps and joins, no fill, nothing inside.
/// Tinted by `foregroundStyle`: Ink at rest, Accent Blue on the Buffs page and on pieces, Quiet
/// when paused or Soon. Drawn on a 72 × 50 grid and scaled to `width`.
public struct BuffSymbol: View {
  /// The sizes the design uses, by width; the height follows the grid.
  public enum Size: CGFloat, Sendable {
    case buffsPage = 40
    case card = 32
    case row = 28
    case menu = 23
    case sidebar = 18
  }

  let buff: Buff
  let width: CGFloat

  public init(_ buff: Buff, size: Size) {
    self.init(buff, width: size.rawValue)
  }

  public init(_ buff: Buff, width: CGFloat) {
    self.buff = buff
    self.width = width
  }

  public var body: some View {
    let scale = width / BuffOutline.gridWidth
    BuffOutline(buff: buff)
      .stroke(
        style: StrokeStyle(lineWidth: 2.8 * scale, lineCap: .round, lineJoin: .round)
      )
      .frame(width: width, height: BuffOutline.gridHeight * scale)
      .accessibilityLabel(buff.name)
  }
}

/// The symbol's centre line on its 72 × 50 grid, scaled to the rect.
struct BuffOutline: Shape {
  static let gridWidth: CGFloat = 72
  static let gridHeight: CGFloat = 50

  let buff: Buff

  func path(in rect: CGRect) -> Path {
    let scale = min(rect.width / Self.gridWidth, rect.height / Self.gridHeight)
    return grid.applying(
      CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale))
  }

  private var grid: Path {
    var path = Path()
    switch buff {
    case .temporary:
      // A stopwatch: the dial, its stem, the crown and the side button.
      path.addEllipse(in: circle(x: 36, y: 27.5, radius: 19.5))
      path.move(to: CGPoint(x: 36, y: 8))
      path.addLine(to: CGPoint(x: 36, y: 3.5))
      path.move(to: CGPoint(x: 31, y: 3))
      path.addLine(to: CGPoint(x: 41, y: 3))
      path.move(to: CGPoint(x: 50.2, y: 12.6))
      path.addLine(to: CGPoint(x: 53.8, y: 9))
    case .backup:
      // A cloud: a flat base and three arcs.
      path.move(to: CGPoint(x: 19, y: 45))
      path.addLine(to: CGPoint(x: 53.5, y: 45))
      path.addCircularArc(to: CGPoint(x: 54.9, y: 24.7), radius: 10.2)
      path.addCircularArc(to: CGPoint(x: 25.3, y: 19.6), radius: 15.4)
      path.addCircularArc(to: CGPoint(x: 19, y: 45), radius: 12.8)
      path.closeSubpath()
    case .organise:
      // An open drawer: the box and its pulled-out lip.
      path.addRect(CGRect(x: 7, y: 15, width: 58, height: 31))
      path.move(to: CGPoint(x: 13, y: 15))
      path.addLines([
        CGPoint(x: 13, y: 15), CGPoint(x: 17, y: 5), CGPoint(x: 55, y: 5), CGPoint(x: 59, y: 15),
      ])
    case .search:
      // A lens and its handle.
      path.addEllipse(in: circle(x: 31, y: 22, radius: 17.5))
      path.move(to: CGPoint(x: 43.6, y: 34.6))
      path.addLine(to: CGPoint(x: 58, y: 47))
    }
    return path
  }

  private func circle(x: CGFloat, y: CGFloat, radius: CGFloat) -> CGRect {
    CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
  }
}

extension Path {
  /// SVG's small, counter-clockwise circular arc (`A r r 0 0 0 x y`) from the current point.
  mutating func addCircularArc(to end: CGPoint, radius: CGFloat) {
    guard let start = currentPoint else { return }
    let half = CGPoint(x: (start.x - end.x) / 2, y: (start.y - end.y) / 2)
    let halfChordSquared = half.x * half.x + half.y * half.y
    let reach = (max(radius * radius - halfChordSquared, 0) / halfChordSquared).squareRoot()
    // The small arc drawn counter-clockwise on screen keeps the centre on this side of the chord.
    let center = CGPoint(
      x: (start.x + end.x) / 2 - reach * half.y,
      y: (start.y + end.y) / 2 + reach * half.x)
    addArc(
      center: center,
      radius: max(radius, halfChordSquared.squareRoot()),
      startAngle: .radians(atan2(start.y - center.y, start.x - center.x)),
      endAngle: .radians(atan2(end.y - center.y, end.x - center.x)),
      clockwise: true)
  }
}
