import SwiftUI

/// Restore Folder…, for the backup chosen on the backup page: the download as a run, into a new
/// folder beside the folder. Nothing in the folder is replaced.
public struct RestoreFolderSheet: View {
  public var state: RestoreFolderState
  /// Cancel: stops a restore under way and removes what it wrote.
  public var onCancel: () -> Void
  /// Hide: the restore carries on in the background, and the folder opens in Finder when it ends.
  public var onHide: () -> Void
  /// Show in Finder, once the folder is back.
  public var onShowInFinder: () -> Void
  /// The fix a problem offers (Choose Folder…, Try Again).
  public var onFix: (RestoreProblem.Fix) -> Void

  public init(
    state: RestoreFolderState,
    onCancel: @escaping () -> Void = {},
    onHide: @escaping () -> Void = {},
    onShowInFinder: @escaping () -> Void = {},
    onFix: @escaping (RestoreProblem.Fix) -> Void = { _ in }
  ) {
    self.state = state
    self.onCancel = onCancel
    self.onHide = onHide
    self.onShowInFinder = onShowInFinder
    self.onFix = onFix
  }

  public var body: some View {
    switch state.step {
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
