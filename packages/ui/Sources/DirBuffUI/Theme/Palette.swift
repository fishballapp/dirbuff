import AppKit
import SwiftUI

/// DirBuff's named colours, each with a light and a dark value. Amber means "needs you" and
/// nothing else; the one accent is Accent Blue.
public enum Palette {
  /// Selection, the default and every fix button, progress, the working arc, a drop target's ring.
  public static let accentBlue = color(0x2B4BD8, dark: 0x4D6AF2)
  /// Under a hovered drop target.
  public static let blueTint = color(0xE9EDFC, dark: 0x26304F)

  /// The needs-you badge: a filled disc with a white "!".
  public static let amber = color(0xC98B00, dark: 0xD69A12)
  /// Needs-you words.
  public static let amberText = color(0x7F5600, dark: 0xF2C35A)
  /// The ground of whatever needs the user.
  public static let amberTint = color(0xFBF2DC, dark: 0x3A2F18)
  /// A needs-you tile's edge and the hairline under its band.
  public static let amberEdge = color(0xEBD9AC, dark: 0x5C4A1E)

  /// Window content.
  public static let paper = color(0xFAFAF7, dark: 0x1F1F1D)
  /// Tiles and buff cards.
  public static let card = color(0xFFFFFF, dark: 0x2A2A27)
  /// A tile's folder band, group headers.
  public static let well = color(0xF3F2ED, dark: 0x252523)
  /// A buff piece, which stays lighter than the panel it sits on in dark mode.
  public static let piece = color(0xFFFFFF, dark: 0x34342F)

  /// Text and every buff symbol at rest.
  public static let ink = color(0x1A1A1A, dark: 0xECEBE6)
  /// Secondary sentences.
  public static let inkSecondary = color(0x4D4D48, dark: 0xBDBCB6)
  /// Locations, setting lines, buff names on rows, column and section heads.
  public static let inkTertiary = color(0x62625D, dark: 0x9C9B95)
  /// Dividers.
  public static let rule = color(0xE4E3DC, dark: 0x33332F)
  /// The sidebar edge, bar and gauge tracks.
  public static let ruleStrong = color(0xD6D5CD, dark: 0x3E3E39)
  /// A paused or Soon symbol, chevrons.
  public static let quiet = color(0x9A9A95, dark: 0x6E6E69)

  /// The toast's near-black bar, the same in both appearances.
  public static let toast = Color(nsColor: rgb(0x282826)).opacity(0.94)

  private static func color(_ light: UInt32, dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
      })
  }

  private static func rgb(_ hex: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1)
  }
}
