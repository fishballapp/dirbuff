import SwiftUI

/// Restore Folder…: the dates a Backup folder can be brought back to, then the download as a run,
/// into a new folder beside it. Nothing in the folder is replaced.
public struct RestoreFolderSheet: View {
  public var state: RestoreFolderState
  /// A date chosen in the list, by snapshot ID.
  public var onSelectDate: (String) -> Void
  /// Restore, with the chosen snapshot's ID.
  public var onRestore: (String) -> Void
  /// Cancel: stops a restore under way and removes what it wrote.
  public var onCancel: () -> Void
  /// Hide: the restore carries on in the background, and the folder opens in Finder when it ends.
  public var onHide: () -> Void
  /// Show in Finder, once the folder is back.
  public var onShowInFinder: () -> Void
  /// The fix a problem offers (Choose Folder…, Try Again).
  public var onFix: (RestoreProblem.Fix) -> Void
  /// Opens the backup with this password.
  public var onSubmitPassword: (String) -> Void

  @State private var password: String

  public init(
    state: RestoreFolderState,
    password: String = "",
    onSelectDate: @escaping (String) -> Void = { _ in },
    onRestore: @escaping (String) -> Void = { _ in },
    onCancel: @escaping () -> Void = {},
    onHide: @escaping () -> Void = {},
    onShowInFinder: @escaping () -> Void = {},
    onFix: @escaping (RestoreProblem.Fix) -> Void = { _ in },
    onSubmitPassword: @escaping (String) -> Void = { _ in }
  ) {
    self.state = state
    self.onSelectDate = onSelectDate
    self.onRestore = onRestore
    self.onCancel = onCancel
    self.onHide = onHide
    self.onShowInFinder = onShowInFinder
    self.onFix = onFix
    self.onSubmitPassword = onSubmitPassword
    self._password = State(initialValue: password)
  }

  public var body: some View {
    switch state.step {
    case .loading:
      RestoreSheetShell {
        Text("Restore \(state.folderName) as it was")
      } content: {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Asking Google Drive which dates the backup holds…")
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
        }
      } buttons: {
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
      }

    case .password(let ask):
      RestoreSheetShell(sentences: [ask.explanation]) {
        Text("The backup has a password")
      } content: {
        RestorePasswordForm(ask: ask, password: $password) { onSubmitPassword(password) }
      } buttons: {
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        Button("Open Backup") { onSubmitPassword(password) }
          .keyboardShortcut(.defaultAction)
          .disabled(password.isEmpty || ask.isChecking)
      }

    case .choose(let dates):
      RestoreSheetShell(sentences: [state.explanation]) {
        HStack(spacing: 5) {
          Text("Restore")
          FolderPill(state.folderName, path: state.folderPath)
          Text("as it was")
        }
      } content: {
        RestoreDateList(dates: dates, selected: state.selectedDateID, onSelect: onSelectDate)
      } buttons: {
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        Button("Restore Folder") { state.selectedDateID.map(onRestore) }
          .keyboardShortcut(.defaultAction)
          .disabled(state.selectedDateID == nil)
      }

    case .restoring(let run):
      RestoreSheetShell(
        sentences: [
          "The folder is written to a temporary place first and moved next to \(state.folderName) when it is whole, so a cancelled restore leaves nothing behind."
        ]
      ) {
        HStack(spacing: 5) {
          Text("Restoring")
          FolderPill(state.folderName, path: state.folderPath)
        }
      } content: {
        RestoreProgressBar(run: run)
      } buttons: {
        Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        Button("Hide", action: onHide)
          .help("Carry on in the background. The folder opens in Finder when it's back.")
      }

    case .done(let name, let path):
      RestoreSheetShell(
        sentences: ["It is next to \(state.folderName), which was left as it was."]
      ) {
        HStack(spacing: 5) {
          FolderPill(name, path: path)
          Text("is back")
        }
      } buttons: {
        Button("Done", action: onCancel).keyboardShortcut(.cancelAction)
        Button("Show in Finder", action: onShowInFinder).keyboardShortcut(.defaultAction)
      }

    case .failed(let problem):
      RestoreSheetShell(sentences: [problem.message]) {
        Text(problem.title)
      } buttons: {
        Button("Close", action: onCancel).keyboardShortcut(.cancelAction)
        if let title = problem.fix.title {
          Button(title) { onFix(problem.fix) }.keyboardShortcut(.defaultAction)
        }
      }
    }
  }
}

/// The snapshots a folder can be restored to, one per row, the newest first.
struct RestoreDateList: View {
  var dates: [RestoreDate]
  var selected: String?
  var onSelect: (String) -> Void

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(dates) { date in
          Button {
            onSelect(date.id)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: selected == date.id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected == date.id ? Palette.accentBlue : Palette.quiet)
                .accessibilityHidden(true)
              Text(date.when)
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
              Spacer(minLength: 8)
              Text(date.detail)
                .font(.subheadline)
                .foregroundStyle(Palette.inkTertiary)
                .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected == date.id ? Palette.blueTint : .clear)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected == date.id ? .isSelected : [])
        }
      }
    }
    .frame(height: min(CGFloat(dates.count) * 30 + 2, 190))
    .background(Palette.card)
    .clipShape(.rect(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.ruleStrong, lineWidth: 1) }
  }
}
