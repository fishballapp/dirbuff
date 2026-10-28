import SwiftUI

/// A quiet icon button with no label or border, for an action on a file or folder in a list or a
/// toolbar: Ink Tertiary, a light fill on hover. It always carries a tooltip naming its action,
/// which is also its accessibility label.
public struct GhostIconButton: View {
  let icon: Icon
  let help: String
  let action: () -> Void

  @State private var isHovered = false
  @Environment(\.colorScheme) private var colorScheme

  public init(_ help: String, systemImage icon: Icon, action: @escaping () -> Void) {
    self.help = help
    self.icon = icon
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      glyph
        .foregroundStyle(Palette.inkTertiary)
        .frame(width: 24, height: 22)
        .background(
          isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07) : .clear,
          in: .rect(cornerRadius: 5)
        )
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .help(help)
    .accessibilityLabel(help)
  }

  @ViewBuilder
  private var glyph: some View {
    switch icon {
    case .system(let name):
      Image(systemName: name)
        .font(.system(size: 13, weight: .regular))
    case .finder:
      FinderGlyph()
        .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        .frame(width: 15, height: 15)
    }
  }
}

extension GhostIconButton {
  /// What the button shows: an SF Symbol by name, or the Finder face, which has no SF Symbol.
  public enum Icon: Sendable, Equatable, ExpressibleByStringLiteral {
    case system(String)
    case finder

    public init(stringLiteral name: String) {
      self = .system(name)
    }
  }

  /// ↶ Put Back.
  public static let putBackSymbol = Icon.system("arrow.uturn.backward")
  /// Show in Finder: the Finder face.
  public static let finderSymbol = Icon.finder
  /// History.
  public static let historySymbol = Icon.system("clock.arrow.circlepath")
}

/// The Finder face as a line drawing on a 16 × 16 grid: a rounded square, the split down its
/// middle, two eyes and a smile.
struct FinderGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    let unit = rect.width / 16
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * unit, y: rect.minY + y * unit)
    }
    var path = Path(
      roundedRect: CGRect(
        origin: point(1.8, 1.8), size: CGSize(width: 12.4 * unit, height: 12.4 * unit)),
      cornerRadius: 3 * unit)
    // The split, with the nose's step.
    path.move(to: point(8.7, 1.8))
    path.addCurve(to: point(7.2, 8.9), control1: point(7.5, 4.3), control2: point(7, 6.6))
    path.addLine(to: point(8.7, 8.9))
    path.addCurve(to: point(9.1, 14.2), control1: point(8.5, 10.7), control2: point(8.7, 12.4))
    // The eyes.
    path.move(to: point(5, 5.4))
    path.addLine(to: point(5, 6.7))
    path.move(to: point(11.1, 5.4))
    path.addLine(to: point(11.1, 6.7))
    // The smile.
    path.move(to: point(4.4, 10.3))
    path.addCurve(to: point(11.6, 10.3), control1: point(6.5, 11.8), control2: point(9.5, 11.8))
    return path
  }
}
