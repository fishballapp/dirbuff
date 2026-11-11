import DirBuffCore
import DirBuffKit
import Foundation

/// Backup's row on `report`'s folder. What decides it, first to last: the licence, a folder
/// DirBuff can't find or open, the Google account and its one backup (`report.drive`, the same for
/// every folder), a run in progress, and then the folder's own record: failing runs, files it
/// couldn't read, days without a backup.
func backupRow(
  _ wear: Wear<BackupSettings>,
  _ reading: Result<BackupStatus, FolderProblem>?,
  in report: FolderReport,
  licence: Licence,
  isWorking: Bool,
  progress: RunProgress?,
  now: Date,
  calendar: Calendar
) -> BuffRow {
  let folder = report.folder
  let setting = backupSetting(wear.settings)
  let status = try? reading?.get()
  func row(_ state: BuffState, _ status: String, setting: String = setting) -> BuffRow {
    BuffRow(buff: .backup, state: state, status: status, setting: setting)
  }
  /// "Not backed up since 09:40" where the folder's record says, else the history.
  let sinceLine = notBackedUpSince(status, now: now, calendar: calendar) ?? setting

  guard !wear.isPausedByLicence, licence.mayClean else {
    return row(.paused(.licence(licence.line?.action ?? .buy)), "Nothing is backed up while paused")
  }
  switch report.problem {
  case .noAccess:
    return row(
      .needsYou(.giveAccess), "macOS took away access",
      setting: folder.accessLostAt.map { "Not backed up for \(timeSince($0, now: now))" }
        ?? setting)
  case .unreachable:
    let drive = volumeName(folder.path) ?? "The drive"
    return row(.paused(.driveUnplugged(drive)), "\(drive) isn't connected")
  case .missing:
    var missing = row(
      .needsYou(.locate), "Can't find",
      setting: folder.missingSince.map {
        "Missing since \(missingDate($0, calendar: calendar))"
      } ?? "Missing")
    missing.statusFolder = report.name
    return missing
  case nil:
    break
  }

  switch report.drive {
  case .ready: break
  case .notSignedIn:
    let waiting = "Waiting for Google sign-in"
    return row(.paused(.waiting(waiting)), waiting, setting: "Backup goes on once you sign in")
  case .signedOut:
    return row(.needsYou(.signInAgain), "Signed out of Google Drive", setting: sinceLine)
  case .otherAccount:
    return row(
      .needsYou(.chooseAccount), "Signed in to another Google account", setting: sinceLine)
  case .full:
    return row(.needsYou(.makeRoom), "Google Drive is full", setting: sinceLine)
  case .backupGone:
    return row(.needsYou(.startAgain), "The backup is gone from Drive", setting: sinceLine)
  case .backupInBin:
    return row(
      .needsYou(.putBackFromDriveBin), "The backup is in Drive's Bin", setting: sinceLine)
  case .partMissing:
    return row(.needsYou(.showDetails), "Part of the backup is missing")
  case .waiting(let wait):
    let words = wait.words(calendar: calendar)
    return row(.paused(.waiting(words)), words)
  }

  if isWorking {
    var working = row(
      .working, progress.flatMap(backedUpOf).map { "Backing up · \($0)" } ?? "Backing up")
    working.progress = progress.flatMap {
      $0.bytesTotal > 0 ? min(1, Double($0.bytesDone) / Double($0.bytesTotal)) : nil
    }
    return working
  }
  guard let status else { return row(.atRest, "Not backed up yet") }

  if status.isFailing(now: now) {
    return row(.needsYou(.backUpNow), "Backups are failing", setting: sinceLine)
  }
  if !status.skipped.isEmpty {
    return row(.needsYou(.showFiles), filesCouldNotBeBackedUp(status.skipped.count))
  }
  if status.isStale(now: now) {
    return row(
      .needsYou(.backUpNow),
      status.lastSuccessAt.map { "Not backed up since \(moment($0, now: now, calendar: calendar))" }
        ?? "Never backed up")
  }
  guard let last = status.lastSuccessAt else { return row(.atRest, "Not backed up yet") }
  let backedUp = "Backed up \(timeSince(last, now: now)) ago"
  return row(
    .atRest,
    status.cloudOnlyCount > 0
      ? "\(backedUp) · \(filesOnlyInICloud(status.cloudOnlyCount))" : backedUp)
}
