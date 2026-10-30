import CoreGraphics

/// Hand-set radii and shadows. Standard controls keep their own shapes.
public enum Metrics {
  /// Tiles and buff cards.
  public static let tileRadius: CGFloat = 12
  /// A row in the sidebar, while a buff is dragged over it or its folder needs you.
  public static let sidebarRowRadius: CGFloat = 9
  /// A buff piece.
  public static let pieceRadius: CGFloat = 8
  /// The toast.
  public static let toastRadius: CGFloat = 11
}
