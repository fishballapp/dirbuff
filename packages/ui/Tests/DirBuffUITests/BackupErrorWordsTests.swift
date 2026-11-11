import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

/// Every failure Backup's actions can meet says what happened in a sentence, never "The operation
/// couldn't be completed. (DirBuffKit.BridgeFailure error 0.)".
@Suite struct BackupErrorWordsTests {
  @Test func offlineThroughTheBridgeSaysSo() {
    #expect(
      backupErrorWords(BridgeFailure.drive(.unreachable))
        == "Google Drive can't be reached. Try again once the Mac is online.")
    #expect(
      backupErrorWords(DriveProblem.unreachable)
        == backupErrorWords(
          BridgeFailure.drive(.unreachable)))
  }

  @Test func eachDriveProblemHasWords() {
    let problems: [DriveProblem] = [
      .signedOut, .storageFull, .dailyUploadLimit, .notFound, .rateLimited, .unreachable,
      .checksumMismatch(sent: "a", stored: nil),
      .rejected(status: 403, reason: "forbidden", message: "Nope"),
    ]
    for problem in problems {
      let words = backupErrorWords(problem)
      #expect(words?.contains("DirBuffKit") == false)
      #expect(words?.hasSuffix(".") == true)
    }
  }

  @Test func theUploadPauseSaysUntilWhen() {
    #expect(
      backupErrorWords(BridgeFailure.uploadPaused(until: now))?.hasPrefix(
        "Google's daily upload limit is reached") == true)
  }

  @Test func backupsOwnFailuresHaveWords() {
    #expect(
      backupErrorWords(BackupBuff.Failure.passwordTooShort(minimum: 12))
        == "A password needs at least 12 characters.")
    #expect(
      backupErrorWords(BackupBuff.Failure.accountProblem(.otherAccount))
        == "DirBuff is signed in to another Google account than the backup's.")
    #expect(
      backupErrorWords(DriveAccount.Failure.backupInAnotherAccount)
        == "This Mac's backup is in another Google account's Drive.")
  }

  @Test func aRestoreSaysWhatHappenedAndWhatToDo() {
    let words = [
      backupErrorWords(BackupBuff.Failure.nothingToRestore),
      backupErrorWords(BackupBuff.Failure.notInBackup("Finance/a.xlsx")),
      backupErrorWords(BackupBuff.Failure.notEnoughRoom(needed: 48_000_000_000, available: 1_000)),
      backupErrorWords(BackupBuff.Failure.cannotWrite(URL(fileURLWithPath: "/Volumes"))),
      backupErrorWords(BackupBuff.Failure.outsideFolder("Finance")),
      backupErrorWords(BackupBuff.Failure.seriesShared("docs")),
      backupErrorWords(BackupBuff.Failure.backupIsEmpty),
    ]
    #expect(words.allSatisfy { ($0?.count ?? 0) > 50 && $0?.hasSuffix(".") == true })
    #expect(words[2]?.contains(bytes(48_000_000_000)) == true)
    #expect(words[2]?.contains(bytes(1_000)) == true)
    #expect(words[3]?.contains("Volumes") == true)
    #expect(words[5]?.contains("docs") == false)
  }

  @Test func resticSaysWhatItPrinted() {
    #expect(
      backupErrorWords(ResticFailure.exited(.failed, message: "Fatal: unable to open config file"))
        == "The backup command stopped: unable to open config file.")
    #expect(
      backupErrorWords(ResticFailure.exited(.lockFailed, message: "locked"))
        == "Another backup command is still running. Try again in a few minutes.")
  }

  @Test func whatIsntBackupsHasNoWordsHere() {
    #expect(backupErrorWords(CocoaError(.fileReadNoPermission)) == nil)
  }
}
