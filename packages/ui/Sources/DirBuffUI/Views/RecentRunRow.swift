import SwiftUI

/// One run's removals, with a Put Back button when undoable.
struct RecentRunRow: View {
  var run: RecentRun
  var onPutBack: (RecentRun) -> Void

  var body: some View {
    HStack(spacing: 6) {
      VStack(alignment: .leading, spacing: 1) {
        Text(run.summary).lineLimit(1)
        Text(run.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if run.canPutBack {
        Button("Put Back") { onPutBack(run) }
          .controlSize(.small)
          .accessibilityLabel(run.putBackLabel)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
  }
}
