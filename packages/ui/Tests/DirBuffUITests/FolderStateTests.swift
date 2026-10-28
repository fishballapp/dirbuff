import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func folders(
  _ reports: [FolderReport], licence: Licence = .licensed, working: Set<Int64> = [],
  progress: Engine.RunProgress? = nil, at time: Date = now
) -> [FolderState] {
  FolderState.all(
    reports, licence: licence, working: working, progress: progress, now: time,
    calendar: calendar, binName: "Bin", home: home)
}

private func row(_ report: FolderReport, licence: Licence = .licensed, working: Bool = false)
  -> BuffRow?
{
  folders([report], licence: licence, working: working ? [1] : []).first?.buffs.first
}

// The fixtures' `now` is 08:00, so the next clean-up is at 09:00, an hour away.

@Suite struct TemporaryRow {
  @Test func saysWhatGoesNextTogether() {
    let report = report(
      1, upcoming: [(item("a", size: 1_000), oneDay), (item("b", size: 2_000), oneDay + 60)])
    #expect(row(report)?.status == "2 items go tomorrow · \(bytes(3_000))")
    #expect(row(report)?.state == .atRest)
  }

  @Test func countsDownToTodaysCleanUp() {
    #expect(row(report(1, dueNow: [item("a")]))?.status == "1 item goes in 1 hr · \(bytes(1_000))")
  }

  @Test func saysWhenNothingGoesYet() {
    #expect(row(report(1, items: [item("a")]))?.status == "Nothing goes yet")
  }

  @Test func countsWhatGoesAtRestart() {
    let report = report(1, TemporarySettings(rule: .emptyOnRestart), items: [item("a")])
    #expect(row(report)?.status == "1 item goes at restart · \(bytes(1_000))")
  }

  @Test(arguments: [
    (TemporarySettings(maxAgeDays: 14), "Older than 14 days, to the Bin"),
    (TemporarySettings(maxAgeDays: 1, disposal: .delete), "Older than 1 day, deleted permanently"),
    (TemporarySettings(rule: .size, sizeLimit: 50_000_000_000), "Under 50 GB, to the Bin"),
    (TemporarySettings(rule: .emptyOnRestart), "Emptied at restart, to the Bin"),
    (TemporarySettings(rule: .automatic), "When the disk is nearly full, deleted permanently"),
  ])
  func saysItsSettingInWords(settings: TemporarySettings, words: String) {
    #expect(row(report(1, settings))?.setting == words)
  }

  @Test func needsTheUserWhenMacOSTookAwayAccess() {
    let row = row(report(1, problem: .noAccess, accessLostAt: now - 3 * oneDay - 60))
    #expect(row?.state == .needsYou(.giveAccess))
    #expect(row?.status == "macOS took away access")
    #expect(row?.setting == "Nothing cleared for 3 days")
  }

  @Test(
    arguments: [
      (TimeInterval(30), "1 min"), (20 * 60, "20 min"), (5 * 3_600 + 59, "5 hr"), (oneDay, "1 day"),
    ] as [(TimeInterval, String)])
  func saysHowLongSince(seconds: TimeInterval, words: String) {
    #expect(timeSince(now - seconds, now: now) == words)
  }

  @Test func isPausedWhileItsDriveIsntConnected() {
    let report = report(1, path: "/Volumes/T7 Shuttle/Exports", problem: .unreachable)
    #expect(row(report)?.state == .paused(.driveUnplugged("T7 Shuttle")))
    #expect(row(report)?.status == "T7 Shuttle isn't connected")
  }

  @Test func needsTheUserToLocateAMissingFolder() {
    let since = Date(timeIntervalSince1970: 1_792_664_400)  // Thu 22 Oct 2026, 10:20 UTC
    let row = row(report(1, name: "Projects", problem: .missing, missingSince: since))
    #expect(row?.state == .needsYou(.locate))
    #expect(row?.status == "Can't find" && row?.statusFolder == "Projects")
    #expect(row?.setting.hasPrefix("Missing since Thu") == true)
    #expect(
      folders([report(1, name: "Projects", problem: .missing)]).first?.location
        == "Was at ~/Projects")
  }

  @Test func isPausedOnceTheLicenceEnds() {
    let ended = row(report(1, dueNow: [item("a")]), licence: .ended(paidThrough: now))
    #expect(ended?.state == .paused(.licence(.renew)))
    #expect(ended?.status == "Nothing goes while paused")
    #expect(row(report(1), licence: .trialEnded)?.state == .paused(.licence(.buy)))
  }

  @Test func staysPausedOnceTheLicenceEndTookItOff() {
    let report = report(1, wearsTemporary: false, turnedOffByLicence: true)
    #expect(row(report, licence: .ended(paidThrough: now))?.state == .paused(.licence(.renew)))
  }

  @Test func fillsItsBarAsTheRunGoes() {
    let progress = Engine.RunProgress(
      folderID: 1, itemsDone: 3, itemsTotal: 12, bytesDone: 0, bytesTotal: 0, current: "a")
    #expect(folders([report(1)], working: [1], progress: progress).first?.progress == 0.25)
    #expect(folders([report(1)], working: [1]).first?.progress == 0)
    #expect(folders([report(1)], progress: progress).first?.progress == nil)
  }

  @Test func isWorkingWhileACleanUpRuns() {
    #expect(row(report(1, dueNow: [item("a")]), working: true)?.state == .working)
  }

  @Test func isGoneOnceTakenOff() {
    #expect(row(report(1, wearsTemporary: false)) == nil)
  }
}

@Suite struct FolderMark {
  @Test func isTheMostUrgentBuffsState() {
    #expect(folders([report(1)]).first?.mark == .atRest)
    #expect(folders([report(1, problem: .noAccess)]).first?.mark == .needsYou)
    #expect(folders([report(1, problem: .missing)]).first?.mark == .needsYou)
  }

  @Test func needsTheUserWhileTheLicenceStopsCleaning() {
    #expect(folders([report(1)], licence: .trialEnded).first?.mark == .needsYou)
  }

  @Test func staysAtRestWhileItsDriveIsntConnected() {
    let unplugged = report(1, path: "/Volumes/T7/Exports", problem: .unreachable)
    #expect(folders([unplugged]).first?.mark == .atRest)
  }

  @Test func isGoneWithTheLastBuff() {
    #expect(folders([report(1, wearsTemporary: false)]).isEmpty)
  }

  @Test func leavesOutFoldersThatWearNothing() {
    #expect(folders([report(1, wearsTemporary: false)]).isEmpty)
  }
}

@Suite struct FolderLocation {
  @Test func isShortForTheHomeFolder() {
    #expect(folders([report(1, name: "Downloads")]).first?.location == "~/Downloads")
  }

  @Test func namesTheDriveAndWhatTheFolderHolds() {
    var onDrive = report(1, path: "/Volumes/T7 Shuttle/Exports", items: [item("a", size: 5_000)])
    #expect(folders([onDrive]).first?.location == "T7 Shuttle · \(bytes(5_000))")
    onDrive.reading = .failure(.unreachable)
    #expect(folders([onDrive]).first?.location == "T7 Shuttle")
    #expect(folders([onDrive]).first?.buffs.first?.status == "T7 Shuttle isn't connected")
  }
}

@Suite struct ReadingProblem {
  @Test func tellsLostAccessFromAFolderThatIsGone() {
    #expect(FolderProblem(CocoaError(.fileReadNoPermission)) == .noAccess)
    #expect(FolderProblem(POSIXError(.EPERM)) == .noAccess)
    #expect(FolderProblem(CocoaError(.fileNoSuchFile)) == .unreachable)
  }
}
