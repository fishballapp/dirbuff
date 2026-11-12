import AppKit
import DirBuffKit
import DirBuffUI
import Foundation
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "restore")

/// What the open restore sheets remember between their steps. A backup's password is here only
/// while a sheet is open, or its hidden restore runs: it is kept in the Keychain by Keep Backing
/// Up Here, and nowhere else.
struct RestoreContext {
  // Restore Folder
  var folderID: Int64?
  var folderName = ""
  var folderPath = ""
  /// The backup chosen on the backup page.
  var backup: KeptBackup?
  /// Where it goes when not beside the folder: chosen because the folder isn't on this Mac, or
  /// with Choose Folder….
  var directory: URL?
  /// The backup page's own ask for the password, which then restores again.
  var askForPassword: (@MainActor () -> Void)?
  // Restore from Google Drive
  var mac: BackedUpMac?
  var folders: [BackedUpFolder] = []
  var destination = URL.homeDirectory
  // Both
  var password: String?
  /// Asks again what failed, when the sheet's Try Again is chosen.
  var retry: (@MainActor () -> Void)?
}

/// Restore in the app: Restore Folder from the backup page, and Restore from Google Drive
/// with Keep Backing Up Here. Every failure is turned into a sentence (`RestoreProblem`), and
/// nothing is written over anything: the Kit restores beside the original, or into a new folder.
///
/// A restore runs as a task of its own (`startRestore`), and the Kit's methods are called from it
/// directly, so cancelling the task cancels restic and the Kit cleans up after it. What a task
/// finds when it ends belongs to its run (`isCurrent`): a cancelled or replaced one touches
/// nothing, neither the sheet nor Finder.
extension AppModel {
  // MARK: - Runs

  /// Starts `body` as the restore now running; an earlier one is cancelled.
  func startRestore(_ body: @escaping @MainActor (UUID) async -> Void) {
    restoreTask?.cancel()
    let run = restoreGate.begin()
    restoreTask = Task { await body(run) }
  }

  /// Whether `run` is the restore running now, and wasn't cancelled.
  func isCurrent(_ run: UUID) -> Bool {
    restoreGate.isCurrent(run) && !Task.isCancelled
  }

  /// Cancels the restore running, if any: restic stops, and nothing is written into place.
  func endRestore() {
    restoreTask?.cancel()
    restoreTask = nil
    restoreGate.end()
    restoreRun = nil
  }

  // MARK: - Alerts

  /// A system alert for a problem that stopped a restore with no sheet to say so; Sign In Again…
  /// and Choose Account… open the sign-in sheet.
  func tell(_ problem: RestoreProblem, from error: any Error) async {
    logger.error("A restore failed: \(String(describing: error), privacy: .public)")
    await noteDriveProblem(error)
    let alert = BackupAlert.restoreProblem(problem).makeAlert()
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn, problem.fix.isSignIn else { return }
    askToSignIn(.signInAgain)
  }

  /// A Google answer that is the account's (signed out, full, the backup gone) is recorded, so
  /// the folders say so too.
  func noteDriveProblem(_ error: any Error) async {
    do {
      _ = try await driveAccount.note(error)
    } catch {
      logger.error("Couldn't note the account: \(error.localizedDescription, privacy: .public)")
    }
    await backupAccountDidChange()
  }

  // MARK: - Restore Folder

  /// Restore Folder…, from the backup page: the folder as `backup` saved it comes back as a new
  /// folder beside it, in a sheet that shows the download. `password` is the page's, when this
  /// Mac's Keychain doesn't open the backup.
  /// `directory` is where it goes when the folder isn't on this Mac to go beside;
  /// `askForPassword` is the page's, for Enter Password….
  func restoreFolder(
    folderID: Int64, backup chosen: KeptBackup, password: String?, into directory: URL? = nil,
    askForPassword: (@MainActor () -> Void)? = nil
  ) {
    guard restoreFolderSheet == nil, restoreFromDriveSheet == nil, restoreRun == nil,
      let folder = folder(id: folderID)
    else { return }
    let name = URL(fileURLWithPath: folder.path).lastPathComponent
    restoreContext = RestoreContext(
      folderID: folderID, folderName: name, folderPath: folder.path, backup: chosen,
      directory: directory, askForPassword: askForPassword, password: password)
    let started = RestoreRun(folderName: name, path: folder.path)
    restoreFolderSheet = RestoreFolderState(
      folderName: name, folderPath: folder.path, step: .restoring(started))
    runRestoreFolder(into: directory)
  }

  /// Downloads the backup chosen into a new folder beside the folder, or into `directory` after
  /// Choose Folder….
  private func runRestoreFolder(into directory: URL?) {
    guard let folderID = restoreContext.folderID, let chosen = restoreContext.backup,
      restoreFolderSheet != nil
    else { return }
    let (name, path) = (restoreContext.folderName, restoreContext.folderPath)
    let started = RestoreRun(folderName: name, path: path)
    restoreRun = started
    setRestoreFolder(.restoring(started))
    let (backup, password) = (backup, restoreContext.password)
    startRestore { [self] run in
      let report: @Sendable (RestoreProgress) -> Void = { progress in
        Task { @MainActor in
          self.restoreDidProgress(progress, run: run, name: name, path: path)
        }
      }
      do {
        let restored = try await backup.restoreFolder(
          folderID: folderID, backup: chosen, into: directory, password: password,
          onProgress: report)
        guard isCurrent(run) else { return }
        restoreRun = nil
        if restoreFolderSheet == nil {
          NSWorkspace.shared.activateFileViewerSelecting([restored])
        } else {
          setRestoreFolder(.done(name: restored.lastPathComponent, path: restored.path))
        }
      } catch {
        guard isCurrent(run) else { return }
        restoreRun = nil
        await failRestoreFolder(error)
      }
      forgetHiddenRestore()
    }
  }

  /// A hidden restore that ended has no sheet to try again from: what it held, the password
  /// among it, goes. A sheet still open keeps it for Try Again and Choose Folder… until it closes.
  private func forgetHiddenRestore() {
    guard restoreFolderSheet == nil else { return }
    restoreContext = RestoreContext()
  }

  /// A fix the Restore Folder sheet offers.
  func fixRestoreFolder(_ fix: RestoreProblem.Fix) {
    switch fix {
    case .none: break
    case .chooseFolder:
      guard let directory = NSOpenPanel.chooseFolderToRestoreInto() else { return }
      restoreContext.directory = directory
      runRestoreFolder(into: directory)
    case .signIn, .chooseAccount:
      closeRestoreFolder()
      askToSignIn(.signInAgain)
    case .enterPassword:
      // The backup page asks for it, and restores again once it opens the backup.
      let ask = restoreContext.askForPassword
      closeRestoreFolder()
      ask?()
    case .tryAgain:
      runRestoreFolder(into: restoreContext.directory)
    }
  }

  /// Hide: the restore carries on, and the folder opens in Finder when it is back. A sheet hidden
  /// once its restore has ended (done, or failed) is closed.
  func hideRestoreFolder() {
    restoreFolderSheet = nil
    if restoreRun == nil { restoreContext = RestoreContext() }
  }

  /// Cancel, Done and Close: stops a restore under way, which clears what it wrote.
  func closeRestoreFolder() {
    endRestore()
    restoreFolderSheet = nil
    restoreContext = RestoreContext()
  }

  func showRestoredFolderInFinder() {
    guard case .done(_, let path)? = restoreFolderSheet?.step else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  private func setRestoreFolder(_ step: RestoreFolderState.Step) {
    restoreFolderSheet?.step = step
  }

  /// A restore that failed: in the sheet's words, or, if the sheet was hidden, in an alert that
  /// names the folder and whose sign-in button works.
  private func failRestoreFolder(_ error: any Error) async {
    let problem = RestoreProblem(error, while: .folder(name: restoreContext.folderName))
    guard restoreFolderSheet != nil else {
      await tell(problem, from: error)
      return
    }
    logger.error("A restore failed: \(String(describing: error), privacy: .public)")
    await noteDriveProblem(error)
    setRestoreFolder(.failed(problem))
  }

  fileprivate func restoreDidProgress(
    _ progress: RestoreProgress, run: UUID, name: String, path: String
  ) {
    guard restoreRun != nil, restoreGate.isCurrent(run) else { return }
    let current = RestoreRun(folderName: name, path: path, progress: progress)
    restoreRun = current
    if case .restoring = restoreFolderSheet?.step { setRestoreFolder(.restoring(current)) }
    if case .restoring = restoreFromDriveSheet?.step {
      restoreFromDriveSheet?.step = .restoring(current)
    }
  }
}

extension NSOpenPanel {
  /// Asks where a restored folder goes when the one beside the original can't take it: another
  /// folder, on this disk or another.
  @MainActor
  static func chooseFolderToRestoreInto(
    message: String = "Choose a folder to put the restored folder in"
  ) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.message = message
    panel.prompt = "Restore Here"
    return panel.runModal() == .OK ? panel.url : nil
  }
}
