import DirBuffCore
import SwiftUI

/// The foot of Backup's card: what the backup leaves out, in words, with **Bring Back** on what
/// the user left out, and the folder's latest backups, newest first.
struct BackupCardSections: View {
  var detail: BackupCardDetail
  var onBringBack: (LeaveOut) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        head("Left Out")
        ForEach(detail.leftOut, id: \.self) { line in
          Text(line)
            .font(.subheadline)
            .foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if !detail.userLeftOut.isEmpty {
          Text("You left out:")
            .font(.subheadline)
            .foregroundStyle(Palette.inkSecondary)
            .padding(.top, 4)
          ForEach(detail.userLeftOut) { item in
            HStack(spacing: 10) {
              Text(item.title)
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
              Button("Bring Back") { onBringBack(item.leaveOut) }
                .controlSize(.small)
                .help("Back up \(item.title) again")
            }
          }
        }
      }
      .frame(maxWidth: 620, alignment: .leading)

      VStack(alignment: .leading, spacing: 4) {
        head("Latest Backups")
        if detail.recent.isEmpty {
          Text("None yet.")
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
        } else {
          Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            ForEach(detail.recent) { run in
              GridRow {
                Text(run.when)
                  .foregroundStyle(Palette.inkTertiary)
                Text(run.summary)
                  .foregroundStyle(run.outcome == .failed ? Palette.ink : Palette.inkSecondary)
                  .lineLimit(1)
                  .truncationMode(.tail)
              }
            }
          }
          .font(.subheadline)
          .monospacedDigit()
        }
      }
    }
  }

  private func head(_ title: String) -> some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(Palette.inkTertiary)
      .accessibilityAddTraits(.isHeader)
  }
}
