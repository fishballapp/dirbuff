import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func folders(
  _ reports: [FolderReport], licence: Licence = .licensed, working: Set<Int64> = [],
  at time: Date = now
) -> [FolderState] {
  FolderState.all(
    reports, licence: licence, working: working, now: time, calendar: calendar, binName: "Bin",
    home: home)
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

  @Test func isPausedWhenTheFolderCantBeReached() {
    #expect(row(report(1, problem: .unreachable))?.state == .paused)
    #expect(row(report(1, problem: .unreachable))?.status == "Can't find the folder")
  }

  @Test func isPausedOnceTheLicenceEnds() {
    let row = row(report(1, dueNow: [item("a")]), licence: .ended(paidThrough: now))
    #expect(row?.state == .paused)
    #expect(row?.status == "Nothing goes while paused")
  }

  @Test func staysPausedOnceTheLicenceEndTookItOff() {
    let report = report(1, wearsTemporary: false, turnedOffByLicence: true)
    #expect(row(report, licence: .ended(paidThrough: now))?.state == .paused)
  }

  @Test func isWorkingWhileACleanUpRuns() {
    #expect(row(report(1, dueNow: [item("a")]), working: true)?.state == .working)
  }

  @Test func offersPutBackUntilTheSameTimeTomorrow() {
    let takenOff = now.addingTimeInterval(-3_600)
    let report = report(1, wearsTemporary: false, takenOffAt: takenOff)
    let until = takenOff.addingTimeInterval(oneDay)
    #expect(row(report)?.state == .takenOff(putBackUntil: until))
    #expect(row(report)?.status == "Off · nothing was moved")
    let time = until.formatted(
      Date.FormatStyle(
        date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
    #expect(row(report)?.setting == "A plain folder until tomorrow, \(time)")
    #expect(folders([report], at: until).isEmpty)
  }

  @Test func offersNoPutBackOnceTheLicenceEnds() {
    let report = report(1, wearsTemporary: false, takenOffAt: now)
    #expect(row(report, licence: .ended(paidThrough: now)) == nil)
  }
}

@Suite struct FolderMark {
  @Test func isTheMostUrgentBuffsState() {
    #expect(folders([report(1)]).first?.mark == .atRest)
    #expect(folders([report(1, problem: .noAccess)]).first?.mark == .needsYou)
    #expect(folders([report(1, problem: .unreachable)]).first?.mark == .paused)
  }

  @Test func isGoneWithTheLastBuff() {
    let taken = report(1, wearsTemporary: false, takenOffAt: now)
    #expect(folders([taken]).first?.mark == nil)
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
