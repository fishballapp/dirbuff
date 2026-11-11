import DirBuffKit
import Foundation

/// What went wrong in one of Backup's actions (the password, Put Back, Start Again, a sign-in, a
/// run), as a sentence for an alert or a sheet; nil for an error that isn't Backup's, which the
/// caller words its own way. A Drive problem that came through restic's bridge reads as the Drive
/// problem it is.
public func backupErrorWords(_ error: any Error, calendar: Calendar = .current) -> String? {
  switch error {
  case BridgeFailure.drive(let problem): driveWords(problem)
  case BridgeFailure.uploadPaused(let until):
    "Google's daily upload limit is reached. Backups carry on after "
      + until.formatted(
        Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute()) + "."
  case let problem as DriveProblem: driveWords(problem)
  case let failure as BackupBuff.Failure: backupWords(failure)
  case DriveAccount.Failure.backupInAnotherAccount:
    "This Mac's backup is in another Google account's Drive."
  case let failure as ResticFailure: resticWords(failure)
  case let failure as GoogleSignIn.Failure: signInWords(failure)
  default: nil
  }
}

private func driveWords(_ problem: DriveProblem) -> String {
  switch problem {
  case .signedOut: "DirBuff is signed out of Google Drive. Sign in again, then try again."
  case .storageFull: "Google Drive is full. Make room in it, then try again."
  case .dailyUploadLimit: "Google's daily upload limit is reached. Try again tomorrow."
  case .notFound: "Something DirBuff made in Google Drive is no longer there."
  case .rateLimited: "Google Drive is asking DirBuff to slow down. Try again in a few minutes."
  case .unreachable: "Google Drive can't be reached. Try again once the Mac is online."
  case .checksumMismatch: "Google Drive stored different bytes from those sent. Try again."
  case .rejected(_, _, let message):
    message.isEmpty
      ? "Google Drive refused the request."
      : "Google Drive refused the request: \(sentence(message))"
  }
}

private func backupWords(_ failure: BackupBuff.Failure) -> String {
  switch failure {
  case .passwordNeeded: "The backup has a password, and this Mac doesn't have it."
  case .passwordDoesNotOpen: "The password this Mac keeps no longer opens the backup."
  case .passwordTooShort(let minimum): "A password needs at least \(minimum) characters."
  case .passwordHasSurroundingSpace: "A password can't start or end with a space."
  case .nameWithSlash(let name): "\(name) has a / in it, so it can't be left out by name."
  case .nothingToRestore:
    "That version is a deletion: there's nothing of it to restore. Choose an earlier version."
  case .notInBackup(let path):
    "\(path) isn't in that backup. Older versions thin out with age, so it may no longer hold it: choose another version, or restore the folder as it was on a date the backup still has."
  case .notEnoughRoom(let needed, let available):
    "There isn't room: it needs \(bytes(needed)), and \(bytes(available)) is free where it would go."
  case .cannotWrite(let url):
    "DirBuff can't write into \(url.lastPathComponent). Choose another folder to restore into."
  case .outsideFolder(let path):
    "\(path) now leads out of the folder, so nothing was written. Replace the link with a real folder in Finder, then try again."
  case .seriesShared:
    "Two folders on this Mac would carry on the same backed-up folder. A backed-up folder carries on in one folder only: take Backup off the other, or keep backing up the rest."
  case .backupIsEmpty:
    "That backup holds no snapshot yet, so there is nothing to take over. If Google Drive was slow to answer, try again in a moment."
  case .accountProblem(let problem): accountWords(problem)
  case .notConfirmed: "Nothing was changed: it wasn't confirmed."
  case .cannotStartAgain: "This backup can't be started again."
  }
}

private func accountWords(_ problem: DriveAccountProblem) -> String {
  switch problem {
  case .signedOut: "DirBuff is signed out of Google Drive."
  case .otherAccount: "DirBuff is signed in to another Google account than the backup's."
  case .unconfirmed: "The Google account isn't confirmed yet: finish signing in first."
  case .backupGone: "The backup in Google Drive is gone."
  case .backupInBin: "The backup is in Google Drive's Bin."
  case .full: "Google Drive is full."
  }
}

private func resticWords(_ failure: ResticFailure) -> String {
  switch failure {
  case .exited(.lockFailed, _):
    "Another backup command is still running. Try again in a few minutes."
  case .exited(.wrongPassword, _): "The password doesn't open the backup."
  case .exited(_, let message):
    message.isEmpty
      ? "The backup command stopped." : "The backup command stopped: \(sentence(message))"
  case .stalled: "The backup command stopped making progress, so DirBuff stopped it."
  case .unusable: "DirBuff's copy of restic couldn't be run. Reinstalling DirBuff fixes it."
  }
}

private func signInWords(_ failure: GoogleSignIn.Failure) -> String {
  switch failure {
  case .notConfigured:
    "This copy of DirBuff was built without Google sign-in, so it can't back up."
  case .denied: "Google said DirBuff may not use your Drive. Try again and choose Allow."
  case .driveNotGranted:
    "Google's page had the box for DirBuff's own files unticked, so there is nowhere to back up to. Try again and leave it ticked."
  case .browserUnavailable: "Your browser couldn't be opened. Open it, then try again."
  case .redirectUnavailable:
    "DirBuff couldn't start listening for Google's answer on this Mac. Try again."
  case .timedOut: "Nothing came back from the browser in 5 minutes. Try again when you're ready."
  }
}

/// restic's or Google's message as the end of a sentence: its first line, "Fatal: " dropped,
/// with a full stop.
private func sentence(_ message: String) -> String {
  var line =
    message.split(whereSeparator: \.isNewline).first.map {
      String($0).trimmingCharacters(in: .whitespaces)
    } ?? message
  if line.hasPrefix("Fatal: ") { line.removeFirst("Fatal: ".count) }
  return line.hasSuffix(".") ? line : line + "."
}
