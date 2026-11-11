import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

/// A folder that wears Backup and nothing else, in the fixtures' home.
private func backupReport(
  path: String, status: BackupStatus = BackupStatus(lastRunAt: now, lastSuccessAt: now),
  drive: DriveState = .ready
) -> FolderReport {
  let folder = Folder(id: 1, bookmark: Data(), path: path, createdAt: now)
  let wear = Wear(folderID: 1, settings: BackupSettings(), isPausedByLicence: false, lastRunAt: now)
  return FolderReport(
    folder: folder, location: .success(URL(fileURLWithPath: path)),
    buffs: [.backup(wear, .success(status))], drive: drive)
}

private func detail(
  _ report: FolderReport, account: String? = nil, attempts: [BackupAttempt] = []
) -> BackupCardDetail? {
  let shelf = MainState(
    reports: [report], licence: .licensed, now: now, calendar: calendar, binName: "Bin",
    home: home, startupVolumeName: "Macintosh HD", protectedPaths: [])
  return FolderPageState(
    folderID: 1, reports: [report], shelf: shelf, googleAccount: account,
    backupAttempts: attempts, now: now, calendar: calendar, binName: "Bin", home: home
  )?.cards.first?.backup
}

private func attempt(
  _ secondsAgo: TimeInterval, snapshot: String? = "s", new: Int = 0, changed: Int = 0,
  bytes: Int64 = 0, skipped: Int = 0, error: String? = nil
) -> BackupAttempt {
  BackupAttempt(
    startedAt: now.addingTimeInterval(-secondsAgo), endedAt: now, snapshotID: snapshot,
    filesNew: new, filesChanged: changed, bytesAdded: bytes, skippedCount: skipped, error: error)
}

@Suite struct BackupCard {
  @Test func namesTheAccountTheFilesGoTo() {
    #expect(
      detail(backupReport(path: "\(home)/Documents"), account: "mei@example.com")?.account
        == "mei@example.com")
    #expect(detail(backupReport(path: "\(home)/Documents"))?.account == nil)
  }

  @Test func saysWhatEveryBackupLeavesOut() throws {
    let lines = try #require(detail(backupReport(path: "\(home)/Documents"))?.leftOut)
    #expect(lines.count == 1)
    #expect(lines[0].hasPrefix("Left out everywhere: caches, what macOS keeps out of Time Machine"))
    #expect(lines[0].contains("node_modules"))
  }

  @Test func homeLeavesOutLibraryAndPhotos() throws {
    let lines = try #require(detail(backupReport(path: home))?.leftOut)
    #expect(lines[0].hasPrefix("Library isn't backed up"))
    #expect(lines[1].hasPrefix("Photos library isn't backed up"))
  }

  @Test func picturesSaysPhotosIsntBackedUp() throws {
    let lines = try #require(detail(backupReport(path: "\(home)/Pictures"))?.leftOut)
    #expect(lines.first?.hasPrefix("Photos library isn't backed up") == true)
    let documents = try #require(detail(backupReport(path: "\(home)/Documents"))?.leftOut)
    #expect(!documents.contains { $0.hasPrefix("Photos") })
  }

  @Test func listsWhatTheUserLeftOut() throws {
    let status = BackupStatus(
      lastRunAt: now, lastSuccessAt: now, leftOut: [.path("Taxes/receipts.zip"), .name("build")])
    let card = try #require(detail(backupReport(path: "\(home)/Documents", status: status)))
    // The defaults stay fixed, in words; the user's own each get Bring Back.
    #expect(card.leftOut.count == 1)
    #expect(card.userLeftOut.map(\.title) == ["Taxes/receipts.zip", "Everything called build"])
    #expect(card.userLeftOut.map(\.leaveOut) == [.path("Taxes/receipts.zip"), .name("build")])
  }

  @Test func listsTheLatestBackupsNewestFirst() throws {
    let recent = try #require(
      detail(
        backupReport(path: "\(home)/Documents"),
        attempts: [
          attempt(60, snapshot: nil),
          attempt(3_600, new: 12, changed: 3, bytes: 210_000_000, skipped: 2),
          attempt(7_200),
          attempt(10_800, snapshot: nil, error: "Drive answered 500\nmore"),
        ])?.recent)
    #expect(
      recent.map(\.summary) == [
        "Backing up now",
        "12 new, 3 changed · \(bytes(210_000_000)) · 2 files couldn't be read",
        "No changes",
        "Failed: Drive answered 500",
      ])
    #expect(recent.map(\.outcome) == [.running, .saved, .saved, .failed])
    #expect(recent[0].when.hasPrefix("Today "))
  }

  @Test func listsAtMostFive() {
    let attempts = (1...8).map { attempt(TimeInterval($0) * 3_600) }
    #expect(detail(backupReport(path: "\(home)/Documents"), attempts: attempts)?.recent.count == 5)
  }

  @Test func offersSignInWhileItWaitsForIt() {
    #expect(detail(backupReport(path: "\(home)/Documents", drive: .notSignedIn))?.canSignIn == true)
    #expect(detail(backupReport(path: "\(home)/Documents"))?.canSignIn == false)
  }

  @Test func hasDetailsForAFailureOrWhatTheCheckFound() {
    let failing = BackupStatus(
      lastRunAt: now, lastError: "boom", failingSince: now, failedRunsInARow: 3)
    #expect(detail(backupReport(path: "\(home)/D", status: failing))?.hasDetails == true)
    #expect(detail(backupReport(path: "\(home)/D", drive: .partMissing))?.hasDetails == true)
    #expect(detail(backupReport(path: "\(home)/D"))?.hasDetails == false)
  }
}

@Suite struct BackupHistoryChange {
  @Test func shorterHistoriesKeepLess() {
    #expect(BackupHistory.oneYear.keepsLess(than: .forever))
    #expect(BackupHistory.thirtyDays.keepsLess(than: .oneYear))
    #expect(!BackupHistory.forever.keepsLess(than: .thirtyDays))
    #expect(!BackupHistory.oneYear.keepsLess(than: .oneYear))
  }

  @Test func saysWhatChangedForTheToast() {
    #expect(
      settingChange(from: BackupSettings(), to: BackupSettings(history: .thirtyDays))
        == "keeps versions for 30 days now")
  }
}

@Suite struct GoogleSignInSheetWords {
  @Test func saysWhatDirBuffCanSee() {
    for reason in [
      GoogleSignInState.Reason.backUp(folderName: "Documents", folderPath: "\(home)/Documents"),
      .signInAgain, .settings,
    ] {
      #expect(
        GoogleSignInState(reason: reason).explanation.contains(
          "DirBuff can see only the files it creates there"))
    }
  }

  @Test func namesTheFolderBackupWentOn() {
    let state = GoogleSignInState(
      reason: .backUp(folderName: "Documents", folderPath: "\(home)/Documents"))
    #expect(state.explanation.hasPrefix("Sign in once. DirBuff keeps Documents’ files"))
    #expect(state.confirmTitle == "Start Backup")
    #expect(GoogleSignInState(reason: .signInAgain).confirmTitle == "Carry On")
    #expect(GoogleSignInState(reason: .signInAgain).title == "Sign in to Google Drive again")
  }

  @Test func failingSaysSo() {
    #expect(
      GoogleSignInState(reason: .settings, step: .failed("No")).title
        == "Couldn't sign in to Google")
  }
}

@Suite struct BackupPassword {
  @Test func needsTwelveCharactersTypedTwice() {
    #expect(BackupPasswordSheetState.minimumLength == 12)
    #expect(
      BackupPasswordSheetState.problem(password: "short", confirmation: "short")
        == "At least 12 characters.")
    #expect(
      BackupPasswordSheetState.problem(password: "correct horse", confirmation: "correct hors")
        == "The two don't match yet.")
    #expect(
      BackupPasswordSheetState.problem(password: " correct horse", confirmation: " correct horse")
        == "No space at the start or the end.")
    #expect(
      BackupPasswordSheetState.problem(password: "correct horse", confirmation: "correct horse")
        == nil)
  }

  @Test func settingsSayWhetherThereIsOne() {
    #expect(BackupAccountSettings(isSignedIn: false).accountLine.hasPrefix("Not signed in"))
    #expect(
      BackupAccountSettings(isSignedIn: true, account: "mei@example.com").accountLine
        == "mei@example.com")
    #expect(BackupAccountSettings(isSignedIn: true).passwordLine.hasPrefix("None."))
    #expect(
      BackupAccountSettings(isSignedIn: true, isPasswordProtected: true).passwordLine.hasPrefix(
        "The backup opens only with your password"))
  }
}

@Suite struct UnreadReasons {
  @Test func saysRestics() {
    #expect(unreadReason("open /x/secret: permission denied") == "DirBuff may not read it")
    #expect(unreadReason("open /x/a: resource busy") == "Another app has it open")
    #expect(unreadReason("lstat /x/a: input/output error") == "Input/output error")
    #expect(unreadReason("DirBuff may not read it") == "DirBuff may not read it")
  }
}

@Suite struct BackupAlertWords {
  @Test func takeOffNeedsNoPossessiveOfTheFolder() {
    let alert = BackupAlert.takeOff(folderName: "Documents")
    #expect(alert.title == "Take Backup off Documents?")
    #expect(
      alert.checkbox
        == "Also delete this folder's backup from Google Drive. Its versions can't be brought back."
    )
    #expect(alert.buttons == ["Take Off", "Cancel"])
  }

  @Test func startAgainSaysTheHistoryIsLost() {
    #expect(BackupAlert.startAgain.message.contains("versions are lost"))
    #expect(BackupAlert.startAgain.buttons.first == "Start Again")
  }
}

@Suite struct OtherGoogleAccount {
  @Test func theSheetSaysWhoseDriveTheBackupIsIn() {
    let state = GoogleSignInState(
      reason: .signInAgain,
      step: .otherAccount(owner: "jo@example.com", signedIn: "sam@example.com"))
    #expect(state.title == "This Mac's backup is in jo@example.com’s Drive")
    #expect(state.detail.hasPrefix("You signed in as sam@example.com."))
  }

  @Test func startingANewBackupThereAsksFirst() {
    let alert = BackupAlert.startNewBackup(owner: "jo@example.com", signedIn: "sam@example.com")
    #expect(alert.title == "Start a new backup in sam@example.com’s Drive?")
    #expect(alert.message.contains("stays in jo@example.com’s Drive"))
    #expect(alert.buttons == ["Start New Backup", "Cancel"])
  }

  @Test func theRowNeedsTheUserWithItsOwnFix() {
    let folder = Folder(id: 1, bookmark: Data(), path: "\(home)/Documents", createdAt: now)
    let wear = Wear(
      folderID: 1, settings: BackupSettings(), isPausedByLicence: false, lastRunAt: now)
    let report = FolderReport(
      folder: folder, location: .success(URL(fileURLWithPath: folder.path)),
      buffs: [.backup(wear, .success(BackupStatus(lastRunAt: now, lastSuccessAt: now)))],
      drive: .otherAccount(owner: "jo@example.com"))
    let row = FolderState.all([report], licence: .licensed, now: now, calendar: calendar)[0]
      .buffs[0]
    #expect(row.state == .needsYou(.chooseAccount))
    #expect(row.status == "Signed in to another Google account")
    #expect(Fix.chooseAccount.isSharedByFolders)
  }
}

@Suite struct PasswordSheetAfterAFailure {
  @Test func aFailureAfterTheKeychainChangedSaysThePasswordIsSet() {
    let sheet = BackupPasswordSheetState(mode: .set, isSaving: true)
      .afterFailure("Google Drive can't be reached.", isNewPasswordKept: true)
    #expect(sheet.isFinishing)
    #expect(!sheet.isSaving)
    #expect(sheet.failure == nil)
  }

  @Test func aFailureBeforeItSaysWhy() {
    let sheet = BackupPasswordSheetState(mode: .set, isSaving: true)
      .afterFailure("Google Drive can't be reached.", isNewPasswordKept: false)
    #expect(!sheet.isFinishing)
    #expect(sheet.failure == "Google Drive can't be reached.")
  }

  @Test func anEditAfterAFailureShowsWhatIsWrongNow() {
    let failed = BackupPasswordSheetState(mode: .set, failure: "Google Drive can't be reached.")
    #expect(
      failed.footnote(password: "correct horse", confirmation: "correct horse", isEdited: false)
        == "Google Drive can't be reached.")
    #expect(
      failed.footnote(password: "short", confirmation: "", isEdited: true)
        == "At least 12 characters.")
    #expect(
      failed.footnote(password: "correct horse", confirmation: "correct horse", isEdited: true)
        == nil)
  }
}

@Suite struct UndoingTheHistory {
  @Test func undoingToAShorterHistoryAsksFirst() {
    // 30 days → every version, then Undo: back to 30 days drops what every version kept.
    let toast = SettingsToast(
      change: "keeps every version now", previous: .backup(BackupSettings(history: .thirtyDays)))
    #expect(toast.undoShortensHistory(from: .backup(BackupSettings(history: .forever))))
  }

  @Test func undoingToALongerOneDoesnt() {
    let toast = SettingsToast(
      change: "keeps versions for 30 days now", previous: .backup(BackupSettings(history: .forever))
    )
    #expect(!toast.undoShortensHistory(from: .backup(BackupSettings(history: .thirtyDays))))
    let temporary = SettingsToast(change: "deletes permanently now", previous: TemporarySettings())
    #expect(!temporary.undoShortensHistory(from: .temporary(TemporarySettings())))
  }

  @Test func theConfirmationNamesTheFolder() {
    let words = ShorterHistoryWords(history: .thirtyDays, folderName: "Documents")
    #expect(words.title == "Keep only 30 days of versions of Documents?")
    #expect(words.button == "Keep 30 Days")
  }
}
