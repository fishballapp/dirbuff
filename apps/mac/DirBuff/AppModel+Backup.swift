import DirBuffCore
import DirBuffKit
import Foundation
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "backup")

/// What Backup's driver (`AfterChangeDriver`) asks of the app. Backup shows nothing yet, so this
/// reads the store and runs the module; the surfaces come with Backup's states.
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

  private func isSignedIn() async -> Bool {
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

  /// A run gets no History run yet: `beginRun` drops the empty runs, which would drop one a
  /// backup holds open for hours the next time a clean-up begins one.
  func backUp(folderID: Int64, startedAt: Date) async -> Bool {
    let engine = engine
    let backup = backup
    do {
      try await Task.detached {
        guard let wear = try backup.wear(folderID: folderID), !wear.isPausedByLicence else {
          return
        }
        _ = try await backup.run(
          engine.locate(folderID: folderID), wear,
          context: RunContext(runID: nil, scheduledAt: startedAt))
      }.value
      return true
    } catch {
      logger.error(
        "Backup of folder \(folderID) failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  func checkAccount() async {
    await backupAccount.check()
  }

  /// The day's upkeep, then the weekly check when it's due. A check that couldn't run is tried
  /// at the next upkeep; what one found is kept for the states to show.
  func maintain() async -> Bool {
    guard await isSignedIn() else { return false }
    do {
      try await backup.maintain()
    } catch {
      logger.error("Backup's upkeep failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
    do {
      if try backup.isCheckDue() { try await backup.check() }
    } catch {
      logger.error("Backup's check failed: \(error.localizedDescription, privacy: .public)")
    }
    return true
  }

  /// Sparkle's relaunch for an update waits for `block` while restic runs; false if none does.
  func afterBackupRuns(_ block: @escaping @MainActor () -> Void) -> Bool {
    scheduler?.afterChange.whenIdle(block) ?? false
  }
}
