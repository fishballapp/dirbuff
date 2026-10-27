import AppKit
import SwiftUI

/// The menu-bar glyph's states, by shape: the most urgent across every folder.
public enum MenuBarGlyphState: CaseIterable, Sendable {
  case atRest
  case working
  case needsYou
}

/// The menu-bar glyph: a filled folder with its arm knocked out, in three states told apart by
/// shape. The system tints it, so it is a template image.
public enum MenuBarGlyph {
  /// The glyph for `state`, 22 × 18 pt.
  @MainActor
  public static func image(_ state: MenuBarGlyphState) -> NSImage {
    let renderer = ImageRenderer(
      content: Canvas { context, _ in draw(state, in: &context) }.frame(width: 22, height: 18))
    renderer.scale = 2
    let image = renderer.nsImage ?? NSImage(size: NSSize(width: 22, height: 18))
    image.isTemplate = true
    return image
  }

  /// Draws on the 22 × 18 grid of the design's glyph. Knocked-out shapes erase what's drawn under them.
  private static func draw(_ state: MenuBarGlyphState, in context: inout GraphicsContext) {
    context.fill(folderPath, with: .color(.black))
    var knockOut = context
    knockOut.blendMode = .destinationOut
    knockOut.fill(
      Arm().path(in: CGRect(x: 6.2, y: 5.2, width: 10, height: 10)), with: .color(.black))
    switch state {
    case .atRest:
      return
    case .working:
      knockOut.fill(circle(center: CGPoint(x: 18, y: 13.5), radius: 5.6), with: .color(.black))
      var arc = Path()
      arc.addArc(
        center: CGPoint(x: 18, y: 13.5), radius: 3.3, startAngle: .degrees(-90),
        endAngle: .degrees(153), clockwise: false)
      context.stroke(
        arc, with: .color(.black), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    case .needsYou:
      let disc = CGPoint(x: 17.6, y: 4.6)
      knockOut.fill(circle(center: disc, radius: 5.8), with: .color(.black))
      context.fill(circle(center: disc, radius: 4.3), with: .color(.black))
      var mark = Path()
      mark.move(to: CGPoint(x: 17.6, y: 2.3))
      mark.addLine(to: CGPoint(x: 17.6, y: 5.2))
      knockOut.stroke(
        mark, with: .color(.black), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
      knockOut.fill(circle(center: CGPoint(x: 17.6, y: 7), radius: 0.8), with: .color(.black))
    }
  }

  /// The folder's tab and body, with the design's 1.7 pt corners.
  private static var folderPath: Path {
    var path = Path()
    path.move(to: CGPoint(x: 1, y: 3.2))
    path.addArc(
      tangent1End: CGPoint(x: 1, y: 1.5), tangent2End: CGPoint(x: 2.7, y: 1.5), radius: 1.7)
    path.addLine(to: CGPoint(x: 7.7, y: 1.5))
    path.addLine(to: CGPoint(x: 9.3, y: 3.3))
    path.addLine(to: CGPoint(x: 18.3, y: 3.3))
    path.addArc(
      tangent1End: CGPoint(x: 20, y: 3.3), tangent2End: CGPoint(x: 20, y: 5), radius: 1.7)
    path.addLine(to: CGPoint(x: 20, y: 14.8))
    path.addArc(
      tangent1End: CGPoint(x: 20, y: 16.5), tangent2End: CGPoint(x: 18.3, y: 16.5), radius: 1.7)
    path.addLine(to: CGPoint(x: 2.7, y: 16.5))
    path.addArc(
      tangent1End: CGPoint(x: 1, y: 16.5), tangent2End: CGPoint(x: 1, y: 14.8), radius: 1.7)
    path.closeSubpath()
    return path
  }

  private static func circle(center: CGPoint, radius: CGFloat) -> Path {
    Path(
      ellipseIn: CGRect(
        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
  }
}
