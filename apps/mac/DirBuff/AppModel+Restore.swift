import AppKit
import DirBuffKit
import DirBuffUI
import Foundation
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "restore")

/// What the open restore sheets remember between their steps. A backup's password is here only
/// while a sheet is open: it is kept in the Keychain by Keep Backing Up Here, and nowhere else.
struct RestoreContext {
  // Restore Folder
  var folderID: Int64?
  var folderName = ""
  var folderPath = ""
  var snapshots: [ResticSnapshot] = []
  var chosenSnapshotID: String?
  /// A folder of this Mac whose backup the Keychain no longer opens: the backup's folder it is,
  /// in this Mac's backup, opened with the password typed.
  var passwordSource: BackedUpFolder?
  // Restore from Google Drive
  var mac: BackedUpMac?
  var folders: [BackedUpFolder] = []
  var destination = URL.homeDirectory
  // Both
  var password: String?
  /// Asks again what failed, when the sheet's Try Again is chosen.
  var retry: (@MainActor () -> Void)?
}

/// Restore in the app: Restore a Copy of a file, Restore Folder, and Restore from Google Drive
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

  // MARK: - Restore a Copy

  /// Restores the version of a file beside the original, then shows it in Finder.
  func restoreCopy(_ file: FileVersion, folderID: Int64) async {
    guard versionsCopying == nil else { return }
    versionsCopying = file.id
    versionsToast = nil
    defer { versionsCopying = nil }
    let version = file.version
    do {
      let copy = try await backup.restoreCopy(version, folderID: folderID)
      NSWorkspace.shared.activateFileViewerSelecting([copy])
      versionsToast = VersionsToast(url: copy)
    } catch is CancellationError {
      // Its page went; nothing was written into place and there is nothing to tell.
    } catch {
      let name = URL(fileURLWithPath: version.path).lastPathComponent
      await tell(RestoreProblem(error, while: .copy(name: name)), from: error)
    }
  }

  /// Dismisses the toast after a copy, or when its page goes.
  func dismissVersionsToast() {
    versionsToast = nil
  }

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

  /// Restore Folder…: asks which date, then brings the folder back beside itself.
  func askToRestoreFolder(folderID: Int64) {
    guard restoreFolderSheet == nil, restoreFromDriveSheet == nil, restoreRun == nil,
      let folder = folder(id: folderID)
    else { return }
    let name = URL(fileURLWithPath: folder.path).lastPathComponent
    restoreContext = RestoreContext(folderID: folderID, folderName: name, folderPath: folder.path)
    restoreFolderSheet = RestoreFolderState(folderName: name, folderPath: folder.path)
    loadDates()
  }

  /// The dates the folder can be restored to. With the password typed, the folder is found in
  /// this Mac's backup, opened with it, by the series it carries on; otherwise by the Keychain's.
  private func loadDates() {
    guard let folderID = restoreContext.folderID else { return }
    setRestoreFolder(.loading)
    let (backup, password, name) = (backup, restoreContext.password, restoreContext.folderName)
    startRestore { [self] run in
      do {
        var source: BackedUpFolder?
        var thisMac: BackedUpMac?
        let snapshots: [ResticSnapshot]
        if let password {
          guard let mac = try await backup.backedUpMacs().first(where: \.isThisMac) else {
            throw BackupBuff.Failure.accountProblem(.backupGone)
          }
          let series = try backup.series(of: folderID)
          let folders = try await backup.backedUpFolders(of: mac, password: password)
          guard let found = folders.first(where: { $0.series == series }) else {
            throw BackupBuff.Failure.notInBackup(name)
          }
          (source, thisMac, snapshots) = (found, mac, found.snapshots)
        } else {
          snapshots = try await backup.snapshots(folderID: folderID)
        }
        guard isCurrent(run) else { return }
        restoreContext.snapshots = snapshots
        restoreContext.passwordSource = source
        restoreContext.mac = thisMac
        guard !snapshots.isEmpty else {
          setRestoreFolder(
            .failed(
              RestoreProblem(
                title: "No backup of this folder has finished yet",
                message:
                  "There is nothing to restore until the first backup is done. Back Up Now starts one."
              )))
          return
        }
        setRestoreFolder(.choose(RestoreDate.list(snapshots, now: Date())))
      } catch BackupBuff.Failure.passwordNeeded where isCurrent(run) {
        // The Keychain no longer opens this Mac's backup: the password is asked for here.
        setRestoreFolder(.password(PasswordAsk(macName: "This Mac", isForRestoreFolder: true)))
      } catch BackupBuff.Failure.passwordDoesNotOpen where isCurrent(run) {
        restoreContext.password = nil
        setRestoreFolder(
          .password(PasswordAsk(macName: "This Mac", isWrong: true, isForRestoreFolder: true)))
      } catch {
        guard isCurrent(run) else { return }
        await failRestoreFolder(error)
      }
    }
  }

  /// Opens this Mac's own backup with the password typed, which is kept until the sheet closes.
  func submitRestoreFolderPassword(_ password: String) {
    guard restoreFolderSheet != nil else { return }
    restoreContext.password = password
    setRestoreFolder(
      .password(PasswordAsk(macName: "This Mac", isChecking: true, isForRestoreFolder: true)))
    loadDates()
  }

  /// A date chosen in the list.
  func pickRestoreDate(_ snapshotID: String) {
    restoreFolderSheet?.pickedDateID = snapshotID
  }

  /// Restore Folder, for the snapshot chosen: into a new folder beside the folder, or into
  /// `directory` after Choose Folder….
  func restoreFolder(snapshotID: String, into directory: URL? = nil) {
    guard let folderID = restoreContext.folderID, restoreFolderSheet != nil,
      let snapshot = restoreContext.snapshots.first(where: { $0.id == snapshotID })
    else { return }
    restoreContext.chosenSnapshotID = snapshotID
    let (name, path) = (restoreContext.folderName, restoreContext.folderPath)
    let started = RestoreRun(folderName: name, path: path)
    restoreRun = started
    setRestoreFolder(.restoring(started))
    let (backup, source, mac, password) = (
      backup, restoreContext.passwordSource, restoreContext.mac, restoreContext.password
    )
    startRestore { [self] run in
      let report: @Sendable (RestoreProgress) -> Void = { progress in
        Task { @MainActor in
          self.restoreDidProgress(progress, run: run, name: name, path: path)
        }
      }
      do {
        let restored: URL
        if let source, let mac {
          restored = try await backup.restore(
            snapshot, of: source, from: mac,
            into: directory ?? URL(fileURLWithPath: path).deletingLastPathComponent(),
            password: password, onProgress: report)
        } else {
          restored = try await backup.restoreFolder(
            folderID: folderID, snapshot: snapshot, into: directory, onProgress: report)
        }
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
    }
  }

  /// A fix the Restore Folder sheet offers.
  func fixRestoreFolder(_ fix: RestoreProblem.Fix) {
    switch fix {
    case .none: break
    case .chooseFolder:
      guard let snapshotID = restoreContext.chosenSnapshotID else { return }
      guard let directory = NSOpenPanel.chooseFolderToRestoreInto() else { return }
      restoreFolder(snapshotID: snapshotID, into: directory)
    case .signIn, .chooseAccount:
      closeRestoreFolder()
      askToSignIn(.signInAgain)
    case .enterPassword:
      setRestoreFolder(.password(PasswordAsk(macName: "This Mac", isForRestoreFolder: true)))
    case .tryAgain:
      loadDates()
    }
  }

  /// Hide: the restore carries on, and the folder opens in Finder when it is back.
  func hideRestoreFolder() {
    restoreFolderSheet = nil
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
  static func chooseFolderToRestoreInto() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.message = "Choose a folder to put the restored folder in"
    panel.prompt = "Restore Here"
    return panel.runModal() == .OK ? panel.url : nil
  }
}

extension AppModel {
  /// A folder's versions as Show Versions… lists them, read from the database off the main actor.
  func versionsState(folderID: Int64, now: Date) async -> VersionsState? {
    guard let folder = folder(id: folderID) else { return nil }
    let store = engine.store
    let histories = await Task.detached {
      (try? store.backupFileHistories(folderID: folderID)) ?? []
    }
    .value
    return VersionsState(
      folderID: folderID, folderName: URL(fileURLWithPath: folder.path).lastPathComponent,
      folderPath: folder.path, histories: histories, now: now)
  }
}
