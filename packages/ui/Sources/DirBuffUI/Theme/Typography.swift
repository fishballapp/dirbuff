import CoreText
import SwiftUI

/// The one narrow caps face, Barlow Condensed, bundled with the package. It sets buff names only:
/// never a sentence, button, heading or figure. Everything else is the system font.
public enum Caps {
  public enum Weight: String, Sendable {
    case medium = "Medium"
    case semiBold = "SemiBold"
    case bold = "Bold"
  }

  public static func font(size: CGFloat, weight: Weight = .semiBold) -> Font {
    registerFonts
    return .custom("BarlowCondensed-\(weight.rawValue)", fixedSize: size)
  }

  /// Registers the bundled faces with this process once, on first use.
  private static let registerFonts: Void = {
    let urls = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
    for url in urls {
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
  }()
}

/// A buff's name, uppercase in the caps face, at one of the sizes the design uses.
public struct BuffName: View {
  public enum Size: Sendable {
    /// On a tile's buff row: 10.5 pt, 0.12 em.
    case row
    /// On a buff piece and in + Buff: 13 pt, 0.1 em.
    case piece
    /// Heading a buff card: 14 pt, 0.12 em.
    case card

    var points: CGFloat {
      switch self {
      case .row: 10.5
      case .piece: 13
      case .card: 14
      }
    }

    var trackingEm: CGFloat {
      switch self {
      case .row, .card: 0.12
      case .piece: 0.1
      }
    }
  }

  let buff: Buff
  let size: Size

  public init(_ buff: Buff, size: Size) {
    self.buff = buff
    self.size = size
  }

  public var body: some View {
    Text(buff.name.uppercased())
      .font(Caps.font(size: size.points))
      .tracking(size.points * size.trackingEm)
  }
}
