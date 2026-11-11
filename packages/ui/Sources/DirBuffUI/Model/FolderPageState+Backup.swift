import DirBuffCore
import DirBuffKit
import Foundation

extension CardWords {
  /// Backup's card: the status line the tile has, and a sentence on what happens next or what to
  /// do about it.
  func backupCard(
    _ row: BuffRow, settings: BackupSettings, status: BackupStatus?, drive: DriveState,
    progress: RunProgress?
  ) -> BuffCard {
    var card = BuffCard(
      buff: row.buff, state: row.state, headline: FolderSentence(row.status), detail: nil,
      gauge: nil, settings: .backup(settings), meaning: backupMeaning(settings),
      canShowFiles: false,
      backup: BackupCardDetail(
        account: googleAccount,
        leftOut: backupLeftOut(folder: folderPath, home: home),
        userLeftOut: (status?.leftOut ?? []).map(LeftOutItem.init),
        recent: backupAttempts.prefix(BackupCardDetail.recentCount).map {
          BackupRunLine($0, now: now, calendar: calendar)
        },
        canSignIn: drive == .notSignedIn && row.state.isWaiting,
        hasDetails: drive == .partMissing || status?.lastError != nil))
    switch row.state {
    case .atRest:
      card.detail = FolderSentence(atRestDetail(status))
    case .working:
      card.headline = FolderSentence("Backing up now")
      card.detail = FolderSentence(
        "Changes are saved to your Google Drive, each file once.")
      if let progress {
        card.detail = progress.current.map { FolderSentence("Backing up \($0).") } ?? card.detail
        card.gauge = backedUpOf(progress).flatMap { figure in
          progress.bytesTotal > 0
            ? Gauge(
              kind: .progress,
              fraction: min(1, Double(progress.bytesDone) / Double(progress.bytesTotal)),
              figure: figure)
            : nil
        }
      }
    case .paused(.licence(let action)):
      card.detail = FolderSentence(PauseReason.licence(action).explanation)
    case .paused(.driveUnplugged):
      card.detail = FolderSentence("Nothing is backed up until it's connected again.")
    case .paused(.waiting):
      if case .waiting(let wait) = drive {
        card.detail = FolderSentence(wait.explanation)
      } else {
        card.detail = FolderSentence(
          "Backup goes on once you sign in to Google. Your files stay where they are until then.")
      }
    case .needsYou(let fix):
      card.detail = needsYouDetail(fix, row: row, status: status, drive: drive)
      if fix == .locate { card.headline = FolderSentence(row.status, pill: .after) }
    }
    return card
  }

  /// What the backup keeps doing, and what it leaves aside.
  private func atRestDetail(_ status: BackupStatus?) -> String {
    guard let status, status.lastSuccessAt != nil else {
      return "The first backup starts within the hour, then every hour after a change."
    }
    let cloudOnly =
      status.cloudOnlyCount > 0
      ? " Files that live only in iCloud aren't included until they're downloaded." : ""
    return "Changes are backed up within an hour of being made." + cloudOnly
  }

  private func needsYouDetail(
    _ fix: Fix, row: BuffRow, status: BackupStatus?, drive: DriveState
  ) -> FolderSentence? {
    switch fix {
    case .giveAccess:
      FolderSentence("\(row.setting). Give DirBuff its access back in Privacy & Security.")
    case .locate:
      FolderSentence(
        "\(row.setting). It may have been deleted or moved. Locate it to turn its buffs back on.")
    case .signInAgain:
      FolderSentence(
        "Google no longer accepts DirBuff's access, so nothing is backed up. Sign in again to carry on. The backup in your Drive is untouched."
      )
    case .makeRoom:
      FolderSentence(
        "Your Google Drive has no room left, so new files can't be backed up. Free some up, or get more from Google. Backup carries on by itself."
      )
    case .chooseAccount:
      FolderSentence(
        "This Mac's backup is in \(drive.owner.map { "\($0)’s" } ?? "another account's") Google Drive, and DirBuff is signed in to another account, so nothing is backed up. Sign in to that account, or start a new backup in this one."
      )
    case .putBackFromDriveBin:
      FolderSentence(
        "Put it back and Backup carries on. Once the Bin is emptied, the backup is gone for good.")
    case .startAgain:
      FolderSentence(
        "It was deleted from your Drive. Starting again makes a new backup, and the old versions are lost."
      )
    case .showDetails:
      FolderSentence("Some versions may not restore. Show Details lists what the check found.")
    case .backUpNow:
      backUpNowDetail(status: status)
    case .showFiles:
      FolderSentence(
        "Each file says why it couldn't be read. Leave out the ones you don't need. This clears once every file is backed up or left out."
      )
    }
  }

  private func backUpNowDetail(status: BackupStatus?) -> FolderSentence {
    guard let status, status.isFailing(now: now) else {
      return FolderSentence("No backup has finished in days. Back Up Now tries again at once.")
    }
    let failed = status.failedRunsInARow
    let lead =
      failed > 1
      ? "The last \(failed) backups failed." : "The last backup failed."
    let error =
      status.lastErrorLine.map {
        " The last error: \($0)\($0.last?.isPunctuation == true ? "" : ".")"
      }
      ?? ""
    return FolderSentence(lead + error + " DirBuff tries again every hour.")
  }
}
