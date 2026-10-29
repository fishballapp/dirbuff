import SwiftUI

/// One run in History's list: the buff's symbol, when, then always how many folders, items and
/// bytes, so the list scans. Lights under the pointer, like any list.
struct HistoryRunRowView: View {
  var run: HistoryRunRow

  @State private var isHovered = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 14) {
      BuffSymbol(run.buff, size: .row)
        .foregroundStyle(Palette.ink)
      VStack(alignment: .leading, spacing: 2) {
        Text(run.when)
          .font(.headline)
          .foregroundStyle(Palette.ink)
        Text(run.summary)
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
      }
      .monospacedDigit()
      .lineLimit(1)
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Palette.quiet)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 16)
    .background(isHovered ? Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.035) : .clear)
    .contentShape(.rect)
    .onHover { isHovered = $0 }
  }
}

extension View {
  /// A card on the window's ground, lifted like a tile: History's list and a run's files.
  func historyCard() -> some View {
    modifier(HistoryCard())
  }
}

private struct HistoryCard: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .background(Palette.card)
      .clipShape(.rect(cornerRadius: Metrics.tileRadius))
      .overlay {
        RoundedRectangle(cornerRadius: Metrics.tileRadius)
          .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.14), lineWidth: 0.5)
      }
      .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.07), radius: 8, x: 0, y: 3)
  }
}
