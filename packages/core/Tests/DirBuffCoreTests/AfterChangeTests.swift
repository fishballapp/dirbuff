import DirBuffCore
import Foundation
import Testing

private let utc: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .gmt
  return calendar
}()

/// 12:00:00 UTC on Wed 14 Oct 2026.
private let noon = Date(timeIntervalSince1970: 1_792_065_600)
private let minute: TimeInterval = 60
private let hour: TimeInterval = 3_600
private let day: TimeInterval = 86_400

private func timer(lastMaintainedAt: Date? = noon) -> AfterChangeTimer {
  let schedule = BuffSchedule.afterChange(
    settle: .seconds(300), spacing: .seconds(3_600), check: .seconds(3_600))
  guard let timer = AfterChangeTimer(schedule, lastMaintainedAt: lastMaintainedAt) else {
    fatalError("not an afterChange schedule")
  }
  return timer
}

/// A timer following folder 1, last run `ago` before `noon`; maintenance and the check are done.
private func following(_ ids: Int64..., lastRun ago: TimeInterval = 2 * hour) -> AfterChangeTimer {
  var timer = timer()
  timer.follow(ids.map { .init(folderID: $0, lastRunAt: noon.addingTimeInterval(-ago)) })
  timer.checked(at: noon)
  return timer
}

private func step(_ timer: AfterChangeTimer, at now: Date, _ conditions: BackupConditions = .clear)
  -> AfterChangeStep
{
  timer.next(now: now, conditions: conditions, calendar: utc)
}

@Suite struct AfterChange {
  // MARK: Change

  @Test func withNoChangeNothingRuns() {
    let timer = following(1)
    #expect(
      step(timer, at: noon)
        == .wait(until: noon.addingTimeInterval(hour), heldBy: nil))
  }

  @Test func aChangedFolderRunsOnceItHasBeenQuietForTheSettleTime() {
    var timer = following(1)
    timer.changed(1, at: noon)
    #expect(
      step(timer, at: noon.addingTimeInterval(299))
        == .wait(until: noon.addingTimeInterval(300), heldBy: nil))
    #expect(
      step(timer, at: noon.addingTimeInterval(300))
        == .run(folderID: 1, dueAt: noon.addingTimeInterval(300)))
  }

  @Test func eachChangeRestartsTheSettleTime() {
    var timer = following(1)
    timer.changed(1, at: noon)
    timer.changed(1, at: noon.addingTimeInterval(200))
    #expect(
      step(timer, at: noon.addingTimeInterval(300))
        == .wait(until: noon.addingTimeInterval(500), heldBy: nil))
  }

  @Test func aLateEventDoesNotMoveTheChangeEarlier() {
    var timer = following(1)
    timer.changed(1, at: noon.addingTimeInterval(200))
    timer.changed(1, at: noon)
    #expect(timer.dueAt(1, now: noon) == noon.addingTimeInterval(500))
  }

  @Test func aSettledFolderStillWaitsForTheSpacingAfterItsLastRun() {
    var timer = following(1, lastRun: 20 * minute)
    timer.changed(1, at: noon.addingTimeInterval(-10 * minute))
    // Quiet since 11:50, settled at 11:55; the last run was at 11:40, so 12:40 is the earliest.
    #expect(timer.dueAt(1, now: noon) == noon.addingTimeInterval(40 * minute))
    #expect(
      step(timer, at: noon)
        == .wait(until: noon.addingTimeInterval(40 * minute), heldBy: nil))
  }

  @Test func aFolderNeverBackedUpIsOwedAtOnce() {
    var timer = timer()
    timer.follow([.init(folderID: 1, lastRunAt: nil)])
    timer.checked(at: noon)
    #expect(step(timer, at: noon) == .run(folderID: 1, dueAt: .distantPast))
  }

  // MARK: Daily

  @Test func everyFolderRunsOnceADayEvenWithNoChange() {
    let timer = following(1, lastRun: day)
    #expect(step(timer, at: noon) == .run(folderID: 1, dueAt: noon))
    #expect(following(1, lastRun: day - 1).dueAt(1, now: noon) == noon.addingTimeInterval(1))
  }

  @Test func aChangeNeverPushesTheDailyRunLater() {
    var timer = following(1, lastRun: day - 10 * minute)
    timer.changed(1, at: noon)
    // The change would settle in 5 minutes, but the spacing from the last run is long over.
    #expect(timer.dueAt(1, now: noon) == noon.addingTimeInterval(5 * minute))
  }

  @Test func aLastRunInTheFutureCountsAsNow() {
    var timer = timer()
    timer.follow([.init(folderID: 1, lastRunAt: noon.addingTimeInterval(10 * day))])
    #expect(timer.dueAt(1, now: noon) == noon.addingTimeInterval(day))
  }

  // MARK: Runs

  @Test func theFolderOwedLongestRunsFirst() {
    var timer = timer()
    timer.follow([
      .init(folderID: 1, lastRunAt: noon.addingTimeInterval(-25 * hour)),
      .init(folderID: 2, lastRunAt: noon.addingTimeInterval(-30 * hour)),
      .init(folderID: 3, lastRunAt: noon.addingTimeInterval(-26 * hour)),
    ])
    timer.checked(at: noon)
    #expect(timer.owed(at: noon).map(\.folderID) == [2, 3, 1])
    #expect(step(timer, at: noon) == .run(folderID: 2, dueAt: noon.addingTimeInterval(-6 * hour)))
  }

  @Test func aRunOwedThroughSleepRunsOnWaking() {
    var timer = following(1)
    timer.changed(1, at: noon)
    // The Mac slept through the whole settle time and the next three hours.
    let woke = noon.addingTimeInterval(3 * hour)
    #expect(step(timer, at: woke) == .check)
    timer.checked(at: woke)
    #expect(step(timer, at: woke) == .run(folderID: 1, dueAt: noon.addingTimeInterval(300)))
  }

  @Test func whatChangesDuringARunIsForTheNextRun() {
    var timer = following(1)
    timer.changed(1, at: noon)
    let began = noon.addingTimeInterval(300)
    timer.began(1, at: began)
    timer.changed(1, at: began.addingTimeInterval(60))
    timer.ended(1, succeeded: true)
    let later = began.addingTimeInterval(120)
    #expect(timer.dueAt(1, now: later) == began.addingTimeInterval(hour))
  }

  @Test func aRunWithNoChangeAfterItLeavesNothingOwed() {
    var timer = following(1)
    timer.changed(1, at: noon)
    timer.began(1, at: noon.addingTimeInterval(300))
    timer.ended(1, succeeded: true)
    #expect(timer.dueAt(1, now: noon.addingTimeInterval(400)) == noon.addingTimeInterval(300 + day))
  }

  @Test func aFailedRunIsTriedAgainAfterTheSpacing() {
    var timer = following(1)
    timer.changed(1, at: noon)
    let began = noon.addingTimeInterval(300)
    timer.began(1, at: began)
    timer.ended(1, succeeded: false)
    #expect(timer.dueAt(1, now: began) == began.addingTimeInterval(hour))
  }

  @Test func aFailedRunWithNoChangeIsStillTriedAgainSoon() {
    var timer = following(1, lastRun: day)
    timer.began(1, at: noon)
    timer.ended(1, succeeded: false)
    #expect(timer.dueAt(1, now: noon) == noon.addingTimeInterval(hour))
  }

  // MARK: Following

  @Test func aFolderTakenOffIsForgottenAndOneStillWornKeepsWhatItKnows() {
    var timer = following(1, 2)
    timer.changed(1, at: noon)
    timer.follow([.init(folderID: 1, lastRunAt: nil)])
    #expect(!timer.follows(2))
    #expect(timer.dueAt(1, now: noon) == noon.addingTimeInterval(300))
  }

  @Test func aChangeToAFolderNotFollowedIsIgnored() {
    var timer = following(1)
    timer.changed(9, at: noon)
    #expect(!timer.follows(9))
  }

  // MARK: Conditions

  @Test(arguments: [
    (BackupConditions(network: .offline, isLowPowerMode: false, power: .mains), BackupHold.offline),
    (
      BackupConditions(network: .expensive, isLowPowerMode: false, power: .mains),
      BackupHold.expensiveNetwork
    ),
    (
      BackupConditions(network: .unmetered, isLowPowerMode: true, power: .mains),
      BackupHold.lowPowerMode
    ),
    (
      BackupConditions(network: .unmetered, isLowPowerMode: false, power: .battery(percent: 19)),
      BackupHold.lowBattery
    ),
  ])
  func anOwedRunWaitsForEachCondition(conditions: BackupConditions, hold: BackupHold) {
    let timer = following(1, lastRun: day)
    #expect(
      step(timer, at: noon, conditions) == .wait(until: noon.addingTimeInterval(hour), heldBy: hold)
    )
  }

  @Test func theBatteryHoldsOnlyBelowTwentyPercentAndOnlyOffMains() {
    let timer = following(1, lastRun: day)
    let twenty = BackupConditions(
      network: .unmetered, isLowPowerMode: false, power: .battery(percent: 20))
    let flatOnMains = BackupConditions(network: .unmetered, isLowPowerMode: false, power: .mains)
    #expect(step(timer, at: noon, twenty) == .run(folderID: 1, dueAt: noon))
    #expect(step(timer, at: noon, flatOnMains) == .run(folderID: 1, dueAt: noon))
  }

  @Test func theNetworkIsToldBeforeLowPowerAndBattery() {
    let everything = BackupConditions(
      network: .offline, isLowPowerMode: true, power: .battery(percent: 3))
    #expect(everything.hold == .offline)
    #expect(
      BackupConditions(network: .expensive, isLowPowerMode: true, power: .battery(percent: 3)).hold
        == .expensiveNetwork)
    #expect(
      BackupConditions(network: .unmetered, isLowPowerMode: true, power: .battery(percent: 3)).hold
        == .lowPowerMode)
  }

  @Test func nothingIsHeldWhenNothingIsOwed() {
    let timer = following(1)
    let offline = BackupConditions(network: .offline, isLowPowerMode: true, power: .mains)
    #expect(
      step(timer, at: noon, offline) == .wait(until: noon.addingTimeInterval(hour), heldBy: nil))
  }

  @Test func theReasonsAreInWords() {
    #expect(
      BackupHold.allCases.map(\.reason) == [
        "Waiting for the internet", "Waiting for Wi-Fi", "Low Power Mode", "On battery",
      ])
  }

  // MARK: The check

  @Test func theCheckRunsAtOnceAndThenEveryCheckInterval() {
    var timer = timer()
    timer.follow([.init(folderID: 1, lastRunAt: noon)])
    #expect(step(timer, at: noon) == .check)
    timer.checked(at: noon)
    #expect(
      step(timer, at: noon.addingTimeInterval(hour - 1))
        == .wait(until: noon.addingTimeInterval(hour), heldBy: nil))
    #expect(step(timer, at: noon.addingTimeInterval(hour)) == .check)
  }

  @Test func theCheckComesBeforeAnOwedRun() {
    var timer = timer()
    timer.follow([.init(folderID: 1, lastRunAt: nil)])
    #expect(step(timer, at: noon) == .check)
  }

  @Test func theCheckNeedsAConnectionButNotAFreeOneOrAFullBattery() {
    var timer = timer()
    timer.follow([.init(folderID: 1, lastRunAt: noon)])
    let offline = BackupConditions(network: .offline, isLowPowerMode: false, power: .mains)
    let slow = BackupConditions(
      network: .expensive, isLowPowerMode: true, power: .battery(percent: 2))
    #expect(step(timer, at: noon, offline) != .check)
    #expect(step(timer, at: noon, slow) == .check)
  }

  @Test func withNoFolderThereIsNothingToCheck() {
    let timer = timer()
    #expect(step(timer, at: noon) == .wait(until: noon.addingTimeInterval(12 * hour), heldBy: nil))
  }

  // MARK: Maintenance

  @Test func maintenanceRunsOnceADayWhenNoFolderIsOwed() {
    var timer = timer(lastMaintainedAt: noon.addingTimeInterval(-day))
    timer.follow([.init(folderID: 1, lastRunAt: noon)])
    timer.checked(at: noon)
    #expect(step(timer, at: noon) == .maintain)
    timer.maintained(at: noon, succeeded: true)
    #expect(
      step(timer, at: noon.addingTimeInterval(minute))
        == .wait(until: noon.addingTimeInterval(hour), heldBy: nil))
  }

  @Test func maintenanceFollowsTheBackupsOwedFirst() {
    var timer = timer(lastMaintainedAt: noon.addingTimeInterval(-day))
    timer.follow([.init(folderID: 1, lastRunAt: nil)])
    timer.checked(at: noon)
    #expect(step(timer, at: noon) == .run(folderID: 1, dueAt: .distantPast))
    timer.began(1, at: noon)
    timer.ended(1, succeeded: true)
    #expect(step(timer, at: noon.addingTimeInterval(minute)) == .maintain)
  }

  @Test func maintenanceIsDueAgainOnTheNextCalendarDay() {
    var timer = timer(lastMaintainedAt: noon)
    timer.follow([.init(folderID: 1, lastRunAt: noon)])
    let shortlyAfterMidnight = noon.addingTimeInterval(12 * hour + minute)
    timer.checked(at: shortlyAfterMidnight)
    #expect(step(timer, at: shortlyAfterMidnight) == .maintain)
  }

  @Test func aFailedMaintenanceIsTriedAgainAfterTheSpacing() {
    var timer = timer(lastMaintainedAt: noon.addingTimeInterval(-day))
    timer.follow([.init(folderID: 1, lastRunAt: noon)])
    timer.checked(at: noon)
    timer.maintained(at: noon, succeeded: false)
    #expect(
      step(timer, at: noon.addingTimeInterval(minute))
        == .wait(until: noon.addingTimeInterval(hour), heldBy: nil))
    timer.checked(at: noon.addingTimeInterval(hour))
    #expect(step(timer, at: noon.addingTimeInterval(hour)) == .maintain)
  }

  @Test func maintenanceWaitsForTheSameConditionsAsARun() {
    var timer = timer(lastMaintainedAt: nil)
    timer.follow([.init(folderID: 1, lastRunAt: noon)])
    timer.checked(at: noon)
    let offline = BackupConditions(network: .offline, isLowPowerMode: false, power: .mains)
    let lowPower = BackupConditions(network: .unmetered, isLowPowerMode: true, power: .mains)
    #expect(
      step(timer, at: noon, offline) == .wait(until: noon.addingTimeInterval(hour), heldBy: nil))
    #expect(
      step(timer, at: noon, lowPower) == .wait(until: noon.addingTimeInterval(hour), heldBy: nil))
    #expect(step(timer, at: noon) == .maintain)
  }

  // MARK: The schedule

  @Test func onlyAnAfterChangeScheduleMakesATimer() {
    #expect(AfterChangeTimer(.onTheHour) == nil)
    let schedule = BuffSchedule.afterChange(
      settle: .seconds(300), spacing: .seconds(3_600), check: .seconds(1_800))
    #expect(AfterChangeTimer(schedule)?.check == 1_800)
  }
}
