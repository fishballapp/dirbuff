import DirBuffCore
import DirBuffKit
import Foundation
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "backup")

/// What Backup's driver (`AfterChangeDriver`) asks of the app. Backup shows nothing yet, so this
/// reads the store and runs the module; the surfaces come with Backup's states.
extension AppModel: AfterChangeWork {
  var isAllowed: Bool { licence.mayClean }

  func followedFolders() async -> [FollowedFolder] {
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

  func maintain() async -> Bool {
    do {
      try await backup.maintain()
      return true
    } catch {
      logger.error("Backup's upkeep failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  /// Sparkle's relaunch for an update waits for `block` while restic runs; false if none does.
  func afterBackupRuns(_ block: @escaping @MainActor () -> Void) -> Bool {
    scheduler?.afterChange.whenIdle(block) ?? false
  }
}
