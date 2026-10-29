import SwiftUI

/// Lays out a sentence's words and controls left to right, wrapping onto a new line where the next
/// piece doesn't fit, each line's pieces centred on one another so a pop-up button sits on the
/// words' line. A piece marked `hugsPrevious` (a comma after a pop-up) takes no space before it.
struct SentenceFlow: Layout {
  var wordSpacing: CGFloat = 4
  var lineSpacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let lines = lines(for: subviews, width: proposal.width ?? .infinity)
    let width = lines.map(\.width).max() ?? 0
    let height =
      lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for line in lines(for: subviews, width: bounds.width) {
      for piece in line.pieces {
        subviews[piece.index].place(
          at: CGPoint(x: bounds.minX + piece.x, y: y + line.height / 2),
          anchor: .leading,
          proposal: ProposedViewSize(piece.size))
      }
      y += line.height + lineSpacing
    }
  }

  private struct Line {
    var pieces: [(index: Int, x: CGFloat, size: CGSize)] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func lines(for subviews: Subviews, width: CGFloat) -> [Line] {
    var lines: [Line] = []
    var line = Line()
    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      let gap = subview[HugsPrevious.self] || line.pieces.isEmpty ? 0 : wordSpacing
      if !line.pieces.isEmpty, line.width + gap + size.width > width {
        lines.append(line)
        line = Line()
      }
      let x = line.pieces.isEmpty ? 0 : line.width + gap
      line.pieces.append((index, x, size))
      line.width = x + size.width
      line.height = max(line.height, size.height)
    }
    if !line.pieces.isEmpty { lines.append(line) }
    return lines
  }
}

private struct HugsPrevious: LayoutValueKey {
  static let defaultValue = false
}

extension View {
  /// In a `SentenceFlow`, sits right after the piece before it, with no space between.
  func hugsPrevious() -> some View {
    layoutValue(key: HugsPrevious.self, value: true)
  }
}
