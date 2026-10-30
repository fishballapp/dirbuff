import AppKit
import SwiftUI

/// A folder's Finder icon with its 💪 mark at the lower left: 64 pt on a shelf tile and folder
/// page, and 28 pt in the sidebar.
public struct MarkedFolderIcon: View {
  public enum Size: Sendable {
    case tile
    case sidebar

    var iconPoints: CGFloat {
      switch self {
      case .tile: 64
      case .sidebar: 28
      }
    }

    var markPoints: CGFloat {
      switch self {
      case .tile: 30
      case .sidebar: 15
      }
    }

    /// Offsets from the square icon frame's bottom-leading corner so the mark sits on the folder
    /// artwork's lower-left edge.
    var markOffset: CGSize {
      switch self {
      case .tile: CGSize(width: -5, height: -2)
      case .sidebar: CGSize(width: -4, height: 1)
      }
    }
  }

  public var path: String
  public var mark: MarkState?
  public var size: Size

  public init(path: String, mark: MarkState?, size: Size = .tile) {
    self.path = path
    self.mark = mark
    self.size = size
  }

  public var body: some View {
    Image(nsImage: folderIcon(atPath: path))
      .resizable()
      .interpolation(.high)
      .frame(width: size.iconPoints, height: size.iconPoints)
      .overlay(alignment: .bottomLeading) {
        if let mark {
          Mark(mark, size: size.markPoints)
            .offset(size.markOffset)
            // Scales in when it arrives, as the surrounding animation times it.
            .transition(.scale)
        }
      }
      .accessibilityHidden(true)
  }
}
