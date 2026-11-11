import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

/// Dates as the rows spell them, formatted with the same `Date.FormatStyle` the app uses, so a
/// test never spells a time or a date and reads the same in every locale.
private var style: Date.FormatStyle {
  Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
}
/// "09:40" or "9:40 AM".
private func timeOfDay(_ date: Date) -> String { date.formatted(style.hour().minute()) }
/// "Sun 09:40".
private func weekdayAndTime(_ date: Date) -> String {
  "\(date.formatted(style.weekday(.abbreviated))) \(timeOfDay(date))"
}
/// "Mon 5 Oct".
private func weekdayAndDate(_ date: Date) -> String {
  date.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
}
private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

/// A folder wearing Backup (and Temporary too when `temporary`), as the app would report it.
private func backup(
  _ id: Int64 = 1,
  name: String? = nil,
  status: BackupStatus? = status(),
  temporary: Bool = false,
  drive: DriveState = .ready,
  problem: FolderProblem? = nil,
  isPausedByLicence: Bool = false,
  accessLostAt: Date? = nil,
  missingSince: Date? = nil,
  path: String? = nil
) -> FolderReport {
  var report = report(
    id, name: name, path: path, wearsTemporary: temporary, problem: problem,
    accessLostAt: accessLostAt, missingSince: missingSince)
  let wear = Wear(
    folderID: id, settings: BackupSettings(), isPausedByLicence: isPausedByLicence,
    lastRunAt: now.addingTimeInterval(-30 * oneDay))
  report.buffs.append(.backup(wear, problem == nil ? status.map { .success($0) } : nil))
  report.drive = drive
  return report
}

private func status(
  lastSuccess: TimeInterval? = 12 * 60, cloudOnly: Int = 0, skipped: [SkippedFile] = [],
  failedRuns: Int = 0, failingFor: TimeInterval = 0, lastError: String? = nil
) -> BackupStatus {
  BackupStatus(
    lastRunAt: now.addingTimeInterval(-(lastSuccess ?? 60)),
    lastSuccessAt: lastSuccess.map { now.addingTimeInterval(-$0) }, lastError: lastError,
    failingSince: failedRuns > 0 ? now.addingTimeInterval(-failingFor) : nil,
    failedRunsInARow: failedRuns, skipped: skipped, cloudOnlyCount: cloudOnly)
}

private func progress(_ id: Int64 = 1, done: Int64 = 1_200_000_000, total: Int64 = 3_400_000_000)
  -> RunProgress
{
  RunProgress(
    folderID: id, itemsDone: 10, itemsTotal: 40, bytesDone: done, bytesTotal: total,
    current: "IMG_2041.heic")
}

private func states(
  _ reports: [FolderReport], licence: Licence = .licensed, backingUp: Set<Int64> = [],
  progress: RunProgress? = nil
) -> [FolderState] {
  FolderState.all(
    reports, licence: licence, backingUp: backingUp, backupProgress: progress, now: now,
    calendar: calendar, binName: "Bin", home: home)
}

/// Backup's row on the only folder.
private func row(
  _ report: FolderReport, licence: Licence = .licensed, backingUp: Bool = false,
  progress: RunProgress? = nil
) -> BuffRow? {
  states([report], licence: licence, backingUp: backingUp ? [1] : [], progress: progress)
    .first?.buffs.first { $0.buff == .backup }
}

@Suite struct BackupAtRest {
  @Test func saysWhenItLastBackedUp() {
    let at = row(backup())
    #expect(at?.state == .atRest)
    #expect(at?.status == "Backed up 12 min ago")
    #expect(at?.setting == "Every version, thinning with age")
  }

  @Test func countsFilesThatLiveOnlyInICloud() {
    #expect(
      row(backup(status: status(lastSuccess: 300, cloudOnly: 120)))?.status
        == "Backed up 5 min ago · 120 files only in iCloud")
    #expect(
      row(backup(status: status(cloudOnly: 1)))?.status
        == "Backed up 12 min ago · 1 file only in iCloud")
  }

  @Test func saysSoBeforeTheFirstBackup() {
    #expect(row(backup(status: status(lastSuccess: nil)))?.status == "Not backed up yet")
    #expect(row(backup(status: nil))?.status == "Not backed up yet")
  }

  @Test func wordsTheHistory() {
    func setting(_ history: BackupHistory) -> String {
      var report = backup()
      report.buffs = report.buffs.map {
        guard case .backup(var wear, let reading) = $0 else { return $0 }
        wear.settings = BackupSettings(history: history)
        return .backup(wear, reading)
      }
      return row(report)?.setting ?? ""
    }
    #expect(setting(.forever) == "Every version, thinning with age")
    #expect(setting(.oneYear) == "Versions kept for one year")
    #expect(setting(.thirtyDays) == "Versions kept for 30 days")
  }
}

@Suite struct BackupWorking {
  @Test func saysHowManyBytesAreIn() {
    let working = row(backup(), backingUp: true, progress: progress())
    #expect(working?.state == .working)
    #expect(working?.status == "Backing up · 1.2 of 3.4 GB")
    #expect(working?.progress == 1_200_000_000.0 / 3_400_000_000.0)
  }

  @Test func saysNothingMoreBeforeTheFirstReport() {
    let working = row(backup(), backingUp: true)
    #expect(working?.status == "Backing up")
    #expect(working?.progress == nil)
  }

  @Test func ignoresAnotherFoldersProgress() {
    let two = states(
      [backup(1), backup(2, name: "Other")], backingUp: [1, 2], progress: progress(2))
    #expect(two[0].buffs.last?.status == "Backing up")
    #expect(two[1].buffs.last?.status == "Backing up · 1.2 of 3.4 GB")
  }

  @Test func leavesTemporaryAtRestWhileOnlyBackupRuns() {
    let folder = states([backup(temporary: true)], backingUp: [1])[0]
    #expect(folder.buffs.map(\.state) == [.atRest, .working])
    #expect(folder.mark == .working)
  }
}

@Suite struct BackupNeedsYou {
  @Test func countsTheFilesItCouldNotRead() {
    let three = [
      SkippedFile(path: "a", reason: "open"), SkippedFile(path: "b", reason: "open"),
      SkippedFile(path: "c", reason: "denied"),
    ]
    let needs = row(backup(status: status(skipped: three)))
    #expect(needs?.state == .needsYou(.showFiles))
    #expect(needs?.status == "3 files couldn't be backed up")
    #expect(
      row(backup(status: status(skipped: [SkippedFile(path: "a", reason: "open")])))?.status
        == "1 file couldn't be backed up")
  }

  @Test func saysFailingAfterThreeRunsInARow() {
    let two = row(backup(status: status(failedRuns: 2, failingFor: 3_600, lastError: "x")))
    #expect(two?.state == .atRest)
    let three = row(
      backup(status: status(lastSuccess: 4 * 3_600, failedRuns: 3, failingFor: 3_600)))
    #expect(three?.state == .needsYou(.backUpNow))
    #expect(three?.status == "Backups are failing")
    #expect(three?.setting == "Not backed up since \(timeOfDay(ago(4 * 3_600)))")
  }

  @Test func saysFailingAfterThreeHoursOfFailures() {
    let hours = row(
      backup(status: status(lastSuccess: 5 * 3_600, failedRuns: 1, failingFor: 3 * 3_600)))
    #expect(hours?.state == .needsYou(.backUpNow))
    let fewer = row(backup(status: status(failedRuns: 1, failingFor: 2 * 3_600)))
    #expect(fewer?.state == .atRest)
  }

  @Test func saysSoWhenNothingHasRunForDays() {
    let stale = row(backup(status: status(lastSuccess: 4 * oneDay)))
    #expect(stale?.state == .needsYou(.backUpNow))
    #expect(stale?.status == "Not backed up since \(weekdayAndTime(ago(4 * oneDay)))")
    #expect(row(backup(status: status(lastSuccess: 2 * oneDay)))?.state == .atRest)
    let never = BackupStatus(lastRunAt: now.addingTimeInterval(-4 * oneDay))
    #expect(row(backup(status: never))?.status == "Never backed up")
  }

  @Test func putsFailingBeforeFilesBeforeStale() {
    let skipped = [SkippedFile(path: "a", reason: "open")]
    let all = status(
      lastSuccess: 4 * oneDay, skipped: skipped, failedRuns: 5, failingFor: 3 * 3_600)
    #expect(row(backup(status: all))?.state == .needsYou(.backUpNow))
    #expect(
      row(backup(status: status(lastSuccess: 4 * oneDay, skipped: skipped)))?.state
        == .needsYou(.showFiles))
  }

  @Test func showsARunInProgressInsteadOfAnOldFailure() {
    let failing = status(lastSuccess: 4 * 3_600, failedRuns: 4, failingFor: 3_600)
    #expect(row(backup(status: failing), backingUp: true)?.state == .working)
  }
}

@Suite struct BackupDriveStates {
  @Test(
    arguments: [
      (DriveState.signedOut, Fix.signInAgain, "Signed out of Google Drive"),
      (.full, .makeRoom, "Google Drive is full"),
      (.backupGone, .startAgain, "The backup is gone from Drive"),
      (.backupInBin, .putBackFromDriveBin, "The backup is in Drive's Bin"),
      (.partMissing, .showDetails, "Part of the backup is missing"),
    ] as [(DriveState, Fix, String)])
  func needsYouWithItsFix(_ drive: DriveState, _ fix: Fix, _ status: String) {
    let needs = row(backup(drive: drive))
    #expect(needs?.state == .needsYou(fix))
    #expect(needs?.status == status)
  }

  @Test func saysSinceWhenForAnAccountThatStoppedBackingUp() {
    let signedOut = row(backup(status: status(lastSuccess: 3 * 3_600), drive: .signedOut))
    #expect(signedOut?.setting == "Not backed up since \(timeOfDay(ago(3 * 3_600)))")
    let longAgo = row(backup(status: status(lastSuccess: 10 * oneDay), drive: .full))
    #expect(longAgo?.setting == "Not backed up since \(weekdayAndDate(ago(10 * oneDay)))")
    #expect(
      row(backup(status: status(lastSuccess: nil), drive: .full))?.setting == "Never backed up")
  }

  @Test func waitsBeforeSignIn() {
    let waiting = row(backup(status: nil, drive: .notSignedIn))
    #expect(waiting?.state == .paused(.waiting("Waiting for Google sign-in")))
    #expect(waiting?.status == "Waiting for Google sign-in")
    #expect(waiting?.setting == "Backup goes on once you sign in")
    #expect(waiting?.state.mark == .atRest)
    #expect(waiting?.state.pillReason == nil)
  }

  @Test(
    arguments: [
      (DriveState.Wait.internet, "Waiting for the internet"),
      (.wifi, "Waiting for Wi-Fi"),
      (.power, "Waiting for power"),
      (.lowPowerMode, "Low Power Mode is on"),
      (
        .googleLimit(resumesAt: now.addingTimeInterval(7_200)),
        "Waiting for Google until \(timeOfDay(now.addingTimeInterval(7_200)))"
      ),
    ] as [(DriveState.Wait, String)])
  func waitsWithNothingToDo(_ wait: DriveState.Wait, _ words: String) {
    let waiting = row(backup(drive: .waiting(wait)))
    #expect(waiting?.state == .paused(.waiting(words)))
    #expect(waiting?.status == words)
    #expect(waiting?.setting == "Every version, thinning with age")
    #expect(waiting?.state.mark == .atRest)
    #expect(waiting?.state.isWaiting == true)
  }

  @Test func theAccountOutranksTheFoldersOwnRecord() {
    let skipped = [SkippedFile(path: "a", reason: "open")]
    #expect(
      row(backup(status: status(skipped: skipped), drive: .full))?.state == .needsYou(.makeRoom))
  }

  @Test func leavesTemporaryAloneWhileDriveFails() {
    let folder = states([backup(temporary: true, drive: .signedOut)])[0]
    #expect(folder.buffs.map(\.buff) == [.temporary, .backup])
    #expect(folder.buffs[0].state == .atRest)
    #expect(folder.buffs[1].state == .needsYou(.signInAgain))
    #expect(folder.mark == .needsYou)
    #expect(folder.isNeedingYou)
  }
}

@Suite struct BackupFolderAndLicence {
  @Test func saysSoWhenMacOSTookAwayAccess() {
    let lost = row(backup(problem: .noAccess, accessLostAt: now.addingTimeInterval(-3 * oneDay)))
    #expect(lost?.state == .needsYou(.giveAccess))
    #expect(lost?.status == "macOS took away access")
    #expect(lost?.setting == "Not backed up for 3 days")
  }

  @Test func pausesOnADriveThatIsntConnected() {
    let away = row(backup(problem: .unreachable, path: "/Volumes/T7 Shuttle/Exports"))
    #expect(away?.state == .paused(.driveUnplugged("T7 Shuttle")))
    #expect(away?.state.mark == .atRest)
  }

  @Test func asksToLocateAMissingFolder() {
    let missing = row(backup(problem: .missing, missingSince: now.addingTimeInterval(-oneDay)))
    #expect(missing?.state == .needsYou(.locate))
    #expect(missing?.status == "Can't find")
    #expect(missing?.statusFolder == "Folder1")
  }

  @Test func pausesWithTheLicence() {
    let paused = row(backup(drive: .signedOut), licence: .trialEnded)
    #expect(paused?.state == .paused(.licence(.buy)))
    #expect(paused?.status == "Nothing is backed up while paused")
    #expect(paused?.state.mark == .needsYou)
    #expect(row(backup(isPausedByLicence: true))?.state == .paused(.licence(.buy)))
  }

  @Test func theFoldersProblemOutranksTheAccount() {
    #expect(row(backup(drive: .full, problem: .noAccess))?.state == .needsYou(.giveAccess))
  }
}

@Suite struct BackupFixes {
  @Test func titlesTheFixes() {
    #expect(Fix.signInAgain.title == "Sign In Again…")
    #expect(Fix.makeRoom.title == "Make Room…")
    #expect(Fix.showFiles.title == "Show Files…")
    #expect(Fix.backUpNow.title == "Back Up Now")
    #expect(Fix.putBackFromDriveBin.title == "Put Back")
    #expect(Fix.startAgain.title == "Start Again…")
    #expect(Fix.showDetails.title == "Show Details…")
  }

  @Test func sharesTheFixesTheAccountCauses() {
    let shared: [Fix] = [.signInAgain, .makeRoom, .putBackFromDriveBin, .startAgain, .showDetails]
    let own: [Fix] = [.giveAccess, .locate, .showFiles, .backUpNow]
    #expect(shared.allSatisfy { $0.isSharedByFolders })
    #expect(own.allSatisfy { !$0.isSharedByFolders })
  }
}

@Suite struct BackupOnEverySurface {
  @Test func readsAReportsBackup() {
    let report = backup(temporary: true)
    #expect(report.backupWear?.settings == BackupSettings())
    #expect(report.backupStatus?.lastSuccessAt != nil)
    #expect(report.buffs.map(\.buff) == [.temporary, .backup])
    #expect(report.temporaryWear != nil)
  }

  @Test func reportsAFolderProblemFromBackupAlone() {
    var report = backup()
    report.buffs = [
      .backup(
        Wear(folderID: 1, settings: BackupSettings(), isPausedByLicence: false, lastRunAt: now),
        .failure(.noAccess))
    ]
    #expect(report.problem == .noAccess)
  }

  @Test func showsTheRowInTheSidebarWithQuietSymbolsOnlyForRealPauses() {
    func condition(_ report: FolderReport, licence: Licence = .licensed) -> SidebarFolder.Condition?
    {
      MainState(
        reports: [report], licence: licence, now: now, calendar: calendar, binName: "Bin",
        home: home, startupVolumeName: "Macintosh HD"
      ).sidebarFolders.first?.condition
    }
    #expect(condition(backup(temporary: true, drive: .waiting(.internet))) == .atRest)
    #expect(condition(backup(drive: .notSignedIn)) == .atRest)
    #expect(condition(backup(drive: .full)) == .needsYou)
    #expect(condition(backup(), licence: .trialEnded) == .paused)
    let row = MainState(
      reports: [backup(temporary: true)], licence: .licensed, now: now, calendar: calendar,
      binName: "Bin", home: home, startupVolumeName: "Macintosh HD"
    ).sidebarFolders.first
    #expect(row?.buffs == [.temporary, .backup])
  }

  @Test func marksTheFolderByItsMostUrgentBuff() {
    #expect(states([backup(drive: .waiting(.wifi))])[0].mark == .atRest)
    #expect(states([backup(temporary: true)], backingUp: [1])[0].mark == .working)
    #expect(states([backup(drive: .signedOut)], backingUp: [1])[0].mark == .needsYou)
  }

  @Test func putsBackupInFindersMenuAndMark() {
    let working = states([backup(temporary: true)], backingUp: [1], progress: progress())
    let snapshot = FinderSnapshot(
      folders: working, licence: .licensed, protectedFolderPaths: [], binName: "Bin")
    #expect(snapshot.folders.first?.mark == .working)
    let menu = snapshot.menu(for: URL(fileURLWithPath: "\(home)/Folder1"))
    let titles = menu.items.map(\.title)
    #expect(titles.contains("Backup · Every version, thinning with age"))
    #expect(titles.contains("Backing up · 1.2 of 3.4 GB"))
    // Backup is worn, so it isn't offered to add; it can be changed or taken off.
    #expect(!menu.items.contains { $0.action == .addBackup })
    #expect(menu.items.contains { $0.action == .takeBackupOff })
    let needs = FinderSnapshot(
      folders: states([backup(drive: .signedOut)]), licence: .licensed, protectedFolderPaths: [],
      binName: "Bin")
    #expect(needs.folders.first?.mark == .needsYou)
    #expect(needs.folders.first?.buffs.first?.nextEvent == "Signed out of Google Drive")
  }

  @Test func offersBackupOnAFolderThatDoesntWearIt() {
    let menu = FinderMenu.addBuff(folderName: "Scratch", isProtected: true)
    let item = menu.items.first { $0.buff == .backup }
    #expect(item?.action == .addBackup)
    #expect(item?.isEnabled == true)
    #expect(Buff.backup.isAvailable)
  }

  @Test func offersTemporaryOnAFolderThatWearsOnlyBackup() {
    let menu = FinderMenu.buffs(
      folderName: "Home",
      worn: [FinderBuff(buff: .backup, setting: "Every version", nextEvent: "Backed up")],
      isProtected: true)
    let temporary = menu.items.first { $0.buff == .temporary && $0.action != .openFolder }
    #expect(temporary?.isEnabled == false)
    #expect(temporary?.subtitle == "Home is protected. DirBuff never clears it.")
  }
}

@Suite struct BackupFolderPage {
  private func card(
    _ report: FolderReport, backingUp: Bool = false, progress: RunProgress? = nil
  ) -> BuffCard? {
    let shelf = MainState(
      reports: [report], licence: .licensed, backingUp: backingUp ? [1] : [],
      backupProgress: progress, now: now, calendar: calendar, binName: "Bin", home: home,
      startupVolumeName: "Macintosh HD", protectedPaths: [])
    return FolderPageState(
      folderID: 1, reports: [report], shelf: shelf, backupProgress: progress, now: now,
      calendar: calendar, binName: "Bin", home: home)?.cards.first { $0.buff == .backup }
  }

  @Test func holdsTheSettingAndWhatItMeans() {
    let card = card(backup())
    #expect(card?.settings == .backup(BackupSettings()))
    #expect(card?.settings.temporary == nil)
    #expect(card?.headline.text == "Backed up 12 min ago")
    #expect(card?.canShowFiles == false)
    #expect(card?.meaning.hasPrefix("Recent versions are all kept") == true)
  }

  @Test func drawsTheRunAsAGauge() {
    let card = card(backup(), backingUp: true, progress: progress())
    #expect(card?.headline.text == "Backing up now")
    #expect(card?.detail?.text == "Backing up IMG_2041.heic.")
    #expect(card?.gauge?.kind == .progress)
    #expect(card?.gauge?.figure == "1.2 of 3.4 GB")
  }

  @Test func saysWhatToDoAboutEachCause() {
    #expect(card(backup(drive: .signedOut))?.detail?.text.contains("Sign in again") == true)
    #expect(card(backup(drive: .full))?.detail?.text.contains("no room left") == true)
    #expect(card(backup(drive: .backupInBin))?.detail?.text.contains("Put it back") == true)
    #expect(
      card(backup(drive: .backupGone))?.detail?.text.contains("old versions are lost") == true)
    #expect(card(backup(drive: .waiting(.internet)))?.detail?.text.contains("online again") == true)
    #expect(
      card(backup(status: nil, drive: .notSignedIn))?.detail?.text.contains("sign in to Google")
        == true)
  }

  @Test func quotesTheLastErrorOfFailingBackups() {
    let failing = status(
      lastSuccess: 6 * 3_600, failedRuns: 4, failingFor: 5 * 3_600,
      lastError: "The connection was lost\nat line 3")
    #expect(
      card(backup(status: failing))?.detail?.text
        == "The last 4 backups failed. The last error: The connection was lost. DirBuff tries again every hour."
    )
  }
}

@Suite struct BackupInThePopover {
  private func popover(
    _ reports: [FolderReport], backingUp: Set<Int64> = [], progress: RunProgress? = nil
  ) -> PopoverState {
    PopoverState(
      folders: states(reports, backingUp: backingUp, progress: progress),
      scheduleLines: scheduleLines(reports, now: now, calendar: calendar),
      backupProgress: progress, licence: .licensed, now: now, calendar: calendar)
  }

  @Test func namesTheFoldersThatShareAFailureInOneCallout() {
    let state = popover([
      backup(1, name: "Documents", drive: .signedOut),
      backup(2, name: "Pictures", drive: .signedOut),
      backup(3, name: "Desktop", drive: .signedOut),
    ])
    #expect(state.headline == "3 folders need you")
    #expect(state.needsYou.count == 1)
    let callout = state.needsYou.first
    #expect(callout?.lead == "Can't back up")
    #expect(callout?.folderName == "Documents")
    #expect(callout?.otherFolders == 2)
    #expect(callout?.reason == "Signed out of Google Drive")
    #expect(callout?.fix == .signInAgain)
  }

  @Test func keepsAFolderOnItsOwnWhenTheCauseIsItsOwn() {
    let skipped = [SkippedFile(path: "a", reason: "open")]
    let state = popover([
      backup(1, name: "Documents", status: status(skipped: skipped)),
      backup(2, name: "Pictures", status: status(skipped: skipped)),
    ])
    #expect(state.needsYou.count == 2)
    #expect(state.needsYou.allSatisfy { $0.otherFolders == 0 && $0.fix == .showFiles })
    #expect(state.headline == "2 folders need you")
  }

  @Test func doesNotJoinDifferentCauses() {
    let state = popover([
      backup(1, name: "Documents", drive: .full),
      backup(2, name: "Pictures", drive: .full),
      report(3, name: "Projects", problem: .noAccess),
    ])
    #expect(state.needsYou.map(\.fix) == [.makeRoom, .giveAccess])
    #expect(state.needsYou.first?.otherFolders == 1)
    #expect(state.headline == "3 folders need you")
    #expect(state.needsYou.first?.lead == "Can't back up")
    #expect(state.needsYou.last?.lead == "Can't clear")
  }

  @Test func leavesTheRestOfTheFoldersAsFine() {
    let state = popover([
      backup(1, name: "Documents", drive: .full), report(2, name: "Downloads"),
    ])
    #expect(state.headline == "1 folder needs you")
    #expect(state.subheadline == "Everything else is fine")
  }

  @Test func leadsWithTheBackupRunning() {
    let state = popover([backup()], backingUp: [1], progress: progress())
    #expect(state.headline == "Backing up Folder1")
    #expect(state.run?.buff == .backup)
    #expect(state.run?.counts == "1.2 of 3.4 GB")
    #expect(state.run?.current == "IMG_2041.heic")
    #expect(state.glyph == .working)
    let two = popover([backup(1), backup(2, name: "Other")], backingUp: [1, 2])
    #expect(two.headline == "Backing up 2 folders")
    #expect(two.run?.counts == nil)
  }

  @Test func letsAShortCleanUpGoFirst() {
    let state = popover(
      [report(1, name: "Downloads"), backup(2, name: "Documents")], backingUp: [2])
    #expect(state.run?.buff == .backup)
    var both = states(
      [report(1, name: "Downloads"), backup(2, name: "Documents")], backingUp: [2])
    both[0].buffs[0].state = .working
    let cleaning = PopoverState(folders: both, licence: .licensed, now: now, calendar: calendar)
    #expect(cleaning.headline == "Clearing Downloads")
    #expect(cleaning.run?.buff == .temporary)
  }

  @Test func addsALineBesideTemporarys() {
    let lines = scheduleLines([backup(temporary: true)], now: now, calendar: calendar)
    #expect(lines == ["Last clean-up 1 min ago · next in 1 hr", "Last backup 12 min ago"])
    #expect(scheduleLines([backup()], now: now, calendar: calendar) == ["Last backup 12 min ago"])
    #expect(scheduleLines([report(1)], now: now, calendar: calendar).count == 1)
  }

  @Test func saysWhatBackupWaitsFor() {
    #expect(
      scheduleLines([backup(drive: .waiting(.internet))], now: now, calendar: calendar)
        == ["Waiting for the internet · last backup 12 min ago"])
    #expect(
      scheduleLines([backup(status: nil, drive: .notSignedIn)], now: now, calendar: calendar)
        == ["Waiting for Google sign-in"])
    #expect(
      scheduleLines([backup(status: status(lastSuccess: nil))], now: now, calendar: calendar)
        == ["No backup yet"])
  }

  @Test func doesNotCallAWaitingBackupPaused() {
    let state = popover([backup(drive: .waiting(.wifi))])
    #expect(state.headline == "The folder is fine")
    #expect(state.subheadline == "Waiting for Wi-Fi · last backup 12 min ago")
    #expect(state.glyph == .atRest)
  }
}

@Suite struct BackupNotifications {
  private func notifications(_ reports: [FolderReport]) -> [BackupNotification] {
    BackupNotification.all(states(reports))
  }

  @Test func saysNothingWhileNothingNeedsYou() {
    #expect(notifications([backup(), backup(2, drive: .waiting(.internet))]).isEmpty)
    #expect(
      notifications([backup(drive: .notSignedIn), backup(2, isPausedByLicence: true)]).isEmpty)
  }

  @Test func oneNotificationForACauseTheFoldersShare() {
    let all = notifications([
      backup(1, name: "Documents", drive: .signedOut),
      backup(2, name: "Pictures", drive: .signedOut),
      backup(3, name: "Projects", drive: .signedOut),
    ])
    #expect(all.count == 1)
    #expect(all.first?.cause == "backup.signInAgain")
    #expect(all.first?.title == "Can't back up Documents and 2 more")
    #expect(all.first?.body == "Signed out of Google Drive")
    #expect(all.first?.folderID == 1)
  }

  @Test func oneForEachFolderForACauseThatIsItsOwn() {
    let skipped = [SkippedFile(path: "a", reason: "open")]
    let all = notifications([
      backup(1, name: "Documents", status: status(skipped: skipped)),
      backup(2, name: "Pictures", status: status(skipped: skipped)),
    ])
    #expect(all.map(\.cause) == ["backup.showFiles.1", "backup.showFiles.2"])
    #expect(all.map(\.title) == ["Can't back up Documents", "Can't back up Pictures"])
    #expect(all.first?.body == "1 file couldn't be backed up")
  }

  @Test func differentCausesAreNotJoined() {
    let all = notifications([
      backup(1, name: "Documents", drive: .full), backup(2, name: "Pictures", drive: .partMissing),
    ])
    #expect(all.map(\.cause) == ["backup.makeRoom", "backup.showDetails"])
  }

  @Test func aMissingFolderNamesItself() {
    let all = notifications([backup(1, name: "Projects", problem: .missing)])
    #expect(all.first?.body == "Can't find Projects")
  }

  @Test func aCleanUpsNeedsYouIsNotBackups() {
    #expect(notifications([report(1, name: "Downloads", problem: .noAccess)]).isEmpty)
  }
}

@Suite struct UnreadFiles {
  @Test func listsEachFileWithWhy() {
    let skipped = [
      SkippedFile(path: "Taxes/2025.numbers", reason: "open /x/Taxes/2025.numbers: resource busy"),
      SkippedFile(path: "Notes.sqlite", reason: "open /x/Notes.sqlite: permission denied"),
      SkippedFile(path: "odd", reason: "lstat /x/odd: input/output error"),
    ]
    let state = UnreadFilesState(backup(1, name: "Documents", status: status(skipped: skipped)))

    #expect(state?.title == "3 files couldn't be backed up")
    #expect(state?.folderName == "Documents")
    #expect(state?.files.map(\.name) == ["2025.numbers", "Notes.sqlite", "odd"])
    #expect(state?.files.map(\.parent) == ["Taxes", "", ""])
    #expect(
      state?.files.map(\.reason) == [
        "Another app has it open", "DirBuff may not read it", "Input/output error",
      ])
  }

  @Test func leavingOutAFileLeavesOutItsPath() {
    let skipped = [SkippedFile(path: "Taxes/2025.numbers", reason: "permission denied")]
    let file = UnreadFilesState(backup(status: status(skipped: skipped)))?.files.first
    #expect(file?.leaveOut == .path("Taxes/2025.numbers"))
  }

  @Test func hasNothingWhenEveryFileWasRead() {
    #expect(UnreadFilesState(backup()) == nil)
    #expect(UnreadFilesState(report(1)) == nil)
  }
}

/// A notifier that posts nothing: it only remembers what it was asked.
actor RecordingNotifier: BackupNotifying {
  private(set) var posted: [BackupNotification] = []
  var isRefusing = false

  func refuse(_ isRefusing: Bool) { self.isRefusing = isRefusing }

  func post(_ notification: BackupNotification) -> Bool {
    guard !isRefusing else { return false }
    posted.append(notification)
    return true
  }
}

@Suite struct BackupAlertsOncePerDay {
  let store: Store
  let notifier = RecordingNotifier()

  init() throws {
    store = try Store.inMemory()
  }

  private func deliver(_ reports: [FolderReport], at date: Date = now) async throws {
    try await BackupAlerts.deliver(
      states(reports), store: store, notifier: notifier, now: date, calendar: calendar)
  }

  @Test func postsACauseOnceADayAndAgainTheNextDayWhileItLasts() async throws {
    let signedOut = [backup(1, name: "Documents", drive: .signedOut)]

    try await deliver(signedOut)
    try await deliver(signedOut, at: now.addingTimeInterval(3 * 3_600))
    #expect(await notifier.posted.map(\.cause) == ["backup.signInAgain"])

    try await deliver(signedOut, at: now.addingTimeInterval(oneDay))
    #expect(await notifier.posted.count == 2)
  }

  @Test func aRelaunchDoesNotRepeatWhatTheDatabaseRemembers() async throws {
    let full = [backup(1, name: "Documents", drive: .full)]
    try await deliver(full)

    // A new notifier stands for a new launch: only the store carries over.
    let afterRelaunch = RecordingNotifier()
    try await BackupAlerts.deliver(
      states(full), store: store, notifier: afterRelaunch, now: now.addingTimeInterval(60),
      calendar: calendar)

    #expect(await afterRelaunch.posted.isEmpty)
  }

  @Test func eachCauseHasItsOwnDay() async throws {
    try await deliver([backup(1, name: "Documents", drive: .signedOut)])
    try await deliver([backup(1, name: "Documents", drive: .full)])
    #expect(await notifier.posted.map(\.cause) == ["backup.signInAgain", "backup.makeRoom"])
  }

  @Test func aNotificationMacOSRefusedIsTriedAgain() async throws {
    let full = [backup(1, name: "Documents", drive: .full)]
    await notifier.refuse(true)
    try await deliver(full)
    #expect(await notifier.posted.isEmpty)

    await notifier.refuse(false)
    try await deliver(full)
    #expect(await notifier.posted.count == 1)
  }
}

@Suite struct BackupCommands {
  @Test func parsesTheTwoCommandsAndNothingElse() throws {
    #expect(BackupCommand.parse((try #require(URL(string: "dirbuff://back-up-now")))) == .backUpNow)
    #expect(BackupCommand.parse((try #require(URL(string: "dirbuff://check-now")))) == .checkNow)
    #expect(BackupCommand.parse((try #require(URL(string: "dirbuff://folder?path=/x")))) == nil)
    #expect(BackupCommand.parse((try #require(URL(string: "https://back-up-now")))) == nil)
  }

  @Test func eachBuildsTheURLItParses() {
    for command in BackupCommand.allCases {
      #expect(command.url.flatMap(BackupCommand.parse) == command)
    }
    #expect(BackupCommand.backUpNow.url?.absoluteString == "dirbuff://back-up-now")
  }

  @Test func aFolderActionIsNotACommand() {
    for action in FinderAction.allCases {
      #expect(action.url(for: URL(fileURLWithPath: "/x")).flatMap(BackupCommand.parse) == nil)
    }
  }
}
