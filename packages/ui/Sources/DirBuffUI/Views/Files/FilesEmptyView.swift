import SwiftUI

/// What the files page says when it has no files to list: a sentence and the one after it.
struct FilesEmptyView: View {
  var title: String
  var detail: String?

  var body: some View {
    VStack(spacing: 6) {
      Text(title).font(.headline).foregroundStyle(Palette.ink)
      if let detail {
        Text(detail).foregroundStyle(Palette.inkSecondary)
      }
    }
    .multilineTextAlignment(.center)
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .combine)
  }
}

/// A folder the page can't read. When the user can fix it, the needs-you callout: the badge, what
/// happened (naming the folder as a pill), and the fix as the blue default button.
struct FilesProblemView: View {
  var problem: FilesProblem
  var folder: MainFolder
  var onFix: (Fix) -> Void

  var body: some View {
    if let fix = problem.fix {
      callout(fix)
    } else {
      FilesEmptyView(title: problem.sentence, detail: problem.detail)
    }
  }

  private func callout(_ fix: Fix) -> some View {
    HStack(alignment: .top, spacing: 10) {
      NeedsYouBadge(size: 20).padding(.top, 1)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text(problem.sentence)
          if let name = problem.folderName {
            FolderPill(name, path: folder.path)
          }
        }
        .font(.headline)
        .foregroundStyle(Palette.amberText)
        if let detail = problem.detail {
          Text(detail).font(.subheadline).foregroundStyle(Palette.inkSecondary)
        }
        Button(fix.title) { onFix(fix) }
          .buttonStyle(.borderedProminent)
          .tint(Palette.accentBlue)
          .controlSize(.small)
          .padding(.top, 4)
      }
    }
    .padding(14)
    .background(Palette.amberTint, in: .rect(cornerRadius: 10))
    .frame(maxWidth: 420)
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }
}
