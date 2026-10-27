import AppKit
import SwiftUI

extension MarkState {
  /// The identifier Finder Sync registers and sets for this badge state.
  public var badgeIdentifier: String {
    switch self {
    case .atRest: "at-rest"
    case .paused: "paused"
    case .working: "working"
    case .needsYou: "needs-you"
    }
  }

  /// Accessibility label for Finder's badge registration.
  public var badgeLabel: String {
    switch self {
    case .atRest: "DirBuff"
    case .paused: "DirBuff: Paused"
    case .working: "DirBuff: Working"
    case .needsYou: "DirBuff: Needs you"
    }
  }
}

extension Mark {
  /// Renders the 20 pt Finder badge image from `Mark` at 2× so the Finder extension and the app
  /// draw from one source. Coloured, non-template, the same in light and dark.
  @MainActor
  public static func badgeImage(for state: MarkState, size: CGFloat = 20) -> NSImage {
    let renderer = ImageRenderer(content: Mark(state, size: size))
    renderer.scale = 2
    let image = renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
    image.size = NSSize(width: size, height: size)
    image.isTemplate = false
    return image
  }
}

extension BuffSymbol {
  /// Renders the 23 × 16 pt menu template image for `buff` at 2×.
  @MainActor
  public static func menuImage(for buff: Buff) -> NSImage {
    let view = BuffSymbol(buff, size: .menu).foregroundStyle(.black)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let height = (BuffOutline.gridHeight * BuffSymbol.Size.menu.rawValue / BuffOutline.gridWidth)
      .rounded()
    let size = NSSize(width: BuffSymbol.Size.menu.rawValue, height: height)
    let image = renderer.nsImage ?? NSImage(size: size)
    image.size = size
    image.isTemplate = true
    return image
  }
}
