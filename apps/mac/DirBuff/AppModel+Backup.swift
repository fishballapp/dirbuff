import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "backup")

/// What Backup's driver (`AfterChangeDriver`) asks of the app: the folders to follow, a backup,
/// the upkeep and the checks. Backup isn't wearable yet; the surfaces come with the buff.
///
/// Signed out of Google, Backup waits: no folder is followed and no upkeep runs, so nothing is
/// owed or fails for it. Signing in has the driver reload.
extension AppModel: AfterChangeWork {
  /// Backup's module, against the Macs' backups in the Google Drive signed in to.
  static func makeBackup(engine: Engine, googleSignIn: GoogleSignIn) -> BackupBuff {
    BackupBuff(
      engine: engine,
      storage: DriveStorage(
        drive: DriveClient(tokens: googleSignIn), store: engine.store, macName: Machine.name),
      cacheDirectory: URL.cachesDirectory.appendingPathComponent("app.fishball.dirbuff/restic"))
  }

  var isAllowed: Bool { licence.mayClean }

  func isSignedIn() async -> Bool {
    do {
      return try await googleSignIn.isSignedIn()
    } catch {
      logger.error(
        "Couldn't read the Google account: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  func followedFolders() async -> [FollowedFolder] {
    guard await isSignedIn() else { return [] }
    let engine = engine
    let backup = backup
    do {
      return try await Task.detached {
        try backup.wearers().filter { !$0.isPausedByLicence }.compactMap { wear in
          // An unplugged or missing folder isn't a failed backup; it is told as its own state.
          guard let located = try? engine.locate(folderID: wear.folderID) else { return nil }
          let status = try backup.read(located, wear)
          // The wear's run time starts when Backup goes on, so a folder never tried is told apart
          // by its status: it is owed at once, not an hour after it was added.
          let hasRun = status.lastSuccessAt != nil || status.failedRunsInARow > 0
          return FollowedFolder(
            folderID: wear.folderID, url: located.url, lastRunAt: hasRun ? status.lastRunAt : nil)
        }
      }.value
    } catch {
      logger.error(
        "Couldn't list Backup's folders: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  /// Backs the folder up under a History run of its own, which is open while it runs. The status
  /// file says it is running at once, and what it did when it ends.
  func backUp(folderID: Int64, startedAt: Date) async -> Bool {
    let engine = engine
    let backup = backup
    let runID = openBackupRun(folderID: folderID, at: startedAt)
    backingUp.insert(folderID)
    await writeBackupStatus()
    let context = RunContext(runID: runID, scheduledAt: startedAt) { progress in
      // A report that lands after its folder finished is dropped.
      Task { @MainActor in
        if self.backingUp.contains(progress.folderID) { self.backupProgress = progress }
      }
    }
    let isDone: Bool
    do {
      try await Task.detached {
        guard let wear = try backup.wear(folderID: folderID), !wear.isPausedByLicence else {
          return
        }
        _ = try await backup.run(engine.locate(folderID: folderID), wear, context: context)
      }.value
      isDone = true
    } catch {
      logger.error(
        "Backup of folder \(folderID) failed: \(error.localizedDescription, privacy: .public)")
      isDone = false
    }
    backingUp.remove(folderID)
    backupProgress = nil
    if let runID {
      do {
        try engine.store.endRun(id: runID)
      } catch {
        logger.error("Couldn't close the run: \(error.localizedDescription, privacy: .public)")
      }
    }
    historyDidChange()
    await refresh()
    await backupDidChange()
    return isDone
  }

  private func openBackupRun(folderID: Int64, at date: Date) -> Int64? {
    do {
      return try engine.store.beginBackupRun(folderID: folderID, at: date)
    } catch {
      logger.error("Couldn't open a run: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// The hourly check, change or not.
  func checkAccount() async {
    await checkBackupAccount()
    await backupAccountDidChange()
  }

  /// The day's upkeep, then the weekly check when it's due. A check that couldn't run is tried
  /// at the next upkeep; what one found is kept for the states to show.
  func maintain() async -> Bool {
    guard await isSignedIn(), !isAccountHeld else { return false }
    do {
      try await backup.maintain()
    } catch {
      logger.error("Backup's upkeep failed: \(String(describing: error), privacy: .public)")
      await backupAccountDidChange()
      return false
    }
    await check(onlyIfDue: true)
    return true
  }

  /// `dirbuff://check-now`: the weekly check, due or not.
  func checkNow() async {
    guard await isSignedIn(), !isAccountHeld else { return }
    await check(onlyIfDue: false)
  }

  private func check(onlyIfDue: Bool) async {
    let backup = backup
    do {
      try await Task.detached {
        if try !onlyIfDue || backup.isCheckDue() { try await backup.check() }
      }.value
    } catch {
      logger.error("Backup's check failed: \(error.localizedDescription, privacy: .public)")
    }
    await refresh()
    await backupDidChange()
  }

  /// A programme outside DirBuff asked (`dirbuff://back-up-now`, `dirbuff://check-now`). Both do
  /// nothing while Backup is signed out or already running.
  func perform(_ command: BackupCommand) {
    guard let afterChange = scheduler?.afterChange else { return }
    switch command {
    case .backUpNow: afterChange.backUpNow()
    case .checkNow: afterChange.checkNow()
    }
  }

  // MARK: - What Backup shows and tells

  /// After a run, a check or the account's check: the status file says what happened, and a
  /// cause that needs the user is told once a day.
  func backupDidChange() async {
    await writeBackupStatus()
    await notifyBackupNeedsYou()
  }

  nonisolated static var backupStatusURL: URL {
    URL.applicationSupportDirectory.appendingPathComponent("DirBuff")
      .appendingPathComponent(BackupStatusFile.fileName)
  }

  /// Rewrites `backup-status.json` from the database, atomically.
  func writeBackupStatus() async {
    let backup = backup
    do {
      try await Task.detached {
        try backup.statusFile().write(to: Self.backupStatusURL)
      }.value
    } catch {
      logger.error(
        "Couldn't write the status file: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func notifyBackupNeedsYou() async {
    do {
      try await BackupAlerts.deliver(
        folders(now: Date()), store: engine.store, notifier: SystemBackupNotifier(),
        now: Date())
    } catch {
      logger.error(
        "Couldn't tell what Backup needs: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Where the Mac's Google Drive stands, as far as DirBuff knows: what the account checks and
  /// failed runs found (`AppModel+BackupAccount`), signed in, whether the last weekly check found
  /// something missing, and what holds an owed run.
  func refreshDriveState() async {
    guard reports.contains(where: { $0.backupWear != nil }) else {
      driveState = .ready
      return
    }
    if let state = accountDriveState() {
      driveState = state
      return
    }
    guard await isSignedIn() else {
      driveState = .notSignedIn
      return
    }
    let backup = backup
    let problem = (try? await Task.detached { try backup.lastCheck()?.problem }.value) ?? nil
    if problem != nil {
      driveState = .partMissing
    } else if let hold = backupHold {
      driveState = .waiting(DriveState.Wait(hold))
    } else {
      driveState = .ready
    }
  }

  // MARK: - Show Files

  /// The files the last backup of the folder couldn't read; nil when it read them all. Backup's
  /// page shows it when the buff goes live.
  func unreadFiles(folderID: Int64) -> UnreadFilesState? {
    report(id: folderID).flatMap(UnreadFilesState.init)
  }

  /// **Leave Out**: the file's path joins the folder's leave-outs, so the row clears and the next
  /// backup doesn't try it.
  func leaveOut(_ file: UnreadFile, folderID: Int64) async {
    let backup = backup
    do {
      try await Task.detached { try backup.leaveOut(file.leaveOut, folderID: folderID) }.value
    } catch {
      show(error, doing: "leave out \(file.name)")
    }
    await refresh()
    await writeBackupStatus()
  }

  /// Sparkle's relaunch for an update waits for `block` while restic runs; false if none does.
  func afterBackupRuns(_ block: @escaping @MainActor () -> Void) -> Bool {
    scheduler?.afterChange.whenIdle(block) ?? false
  }
}
