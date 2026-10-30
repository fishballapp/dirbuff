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
