import DirBuffCore
import Foundation
import Testing

private let day: TimeInterval = 86_400
private let calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
  return calendar
}()
/// 2027-01-15 10:00 UTC.
private let start = Date(timeIntervalSince1970: 1_800_007_200)

private func day(_ text: String) -> ReleaseDay {
  guard let day = ReleaseDay(text) else { preconditionFailure("not a day: \(text)") }
  return day
}

/// A version that came out the day `licensed` was last confirmed.
private let release = day("2027-01-15")

private func licence(
  _ record: LicenceRecord, after interval: TimeInterval, release: ReleaseDay = release
) -> Licence {
  Licence(record, now: start.addingTimeInterval(interval), release: release, calendar: calendar)
}

private let trial = LicenceRecord(trialStartedAt: start - 30 * day)
private let licensed = LicenceRecord(
  trialStartedAt: start - 30 * day, key: "DIRBUFF-1", activationID: "a1", lastCheckedAt: start)

@Suite struct LicenceTests {
  @Test func theTrialCountsCalendarDaysToItsEnd() {
    let record = LicenceRecord(trialStartedAt: start)
    #expect(licence(record, after: 0) == .trial(daysLeft: 14))
    #expect(licence(record, after: 13 * day) == .trial(daysLeft: 1))
    #expect(licence(record, after: 13 * day + 15 * 3_600) == .trial(daysLeft: 0))
  }

  @Test func theTrialEndsFourteenDaysAfterItStarted() {
    let record = LicenceRecord(trialStartedAt: start)
    #expect(licence(record, after: 14 * day - 1) == .trial(daysLeft: 0))
    #expect(licence(record, after: 14 * day) == .trialEnded)
  }

  @Test func aKeyLicensesDirBuffWithinTheOfflineGrace() {
    #expect(licence(licensed, after: 14 * day - 1) == .licensed)
  }

  @Test func noAnswerFromPolarForTheOfflineGracePausesAVersionItDidNotCover() {
    #expect(licence(licensed, after: 14 * day, release: day("2027-01-16")) == .paused)
  }

  @Test func aVersionTheLastAnswerCoveredCleansEvenWithoutAnAnswerForWeeks() {
    #expect(licence(licensed, after: 60 * day, release: day("2027-01-10")) == .licensed)
    #expect(licence(licensed, after: 60 * day, release: day("2027-01-15")) == .licensed)
    #expect(licence(licensed, after: 60 * day, release: day("2027-01-16")) == .paused)
  }

  @Test func aNewAnswerFromPolarResumesCleaning() {
    var record = licensed
    record.lastCheckedAt = start + 20 * day
    #expect(licence(record, after: 20 * day) == .licensed)
  }

  @Test func anEndedLicenceKeepsTheVersionsItWasPaidUpFor() {
    var record = licensed
    record.hasEnded = true
    #expect(
      licence(record, after: 400 * day, release: day("2027-01-10")) == .kept(paidThrough: start))
    #expect(
      licence(record, after: 400 * day, release: day("2027-01-15")) == .kept(paidThrough: start))
  }

  @Test func anEndedLicenceDoesNotCoverAVersionReleasedAfterIt() {
    var record = licensed
    record.hasEnded = true
    #expect(
      licence(record, after: 400 * day, release: day("2027-01-16")) == .ended(paidThrough: start))
  }

  @Test func aLicencePolarNeverConfirmedCoversNothing() {
    let record = LicenceRecord(trialStartedAt: start - 30 * day, key: "DIRBUFF-1", hasEnded: true)
    #expect(licence(record, after: 0, release: day("2000-01-01")) == .ended(paidThrough: nil))
  }

  @Test func aTrialThatEndedWithoutAPurchaseCoversNoVersion() {
    #expect(licence(trial, after: 0, release: day("2000-01-01")) == .trialEnded)
  }

  @Test func onlyTheTrialAndALicenceClean() {
    #expect(Licence.trial(daysLeft: 3).mayClean)
    #expect(Licence.licensed.mayClean)
    #expect(Licence.kept(paidThrough: start).mayClean)
    #expect(!Licence.trialEnded.mayClean)
    #expect(!Licence.paused.mayClean)
    #expect(!Licence.ended(paidThrough: start).mayClean)
  }

  @Test func onlyAConfirmedEndMakesFoldersPlain() {
    #expect(Licence.trialEnded.plainsFolders)
    #expect(Licence.ended(paidThrough: start).plainsFolders)
    #expect(!Licence.kept(paidThrough: start).plainsFolders)
    #expect(!Licence.paused.plainsFolders)
    #expect(!Licence.trial(daysLeft: 0).plainsFolders)
    #expect(!Licence.licensed.plainsFolders)
  }

  @Test func aLicenceThatLapsedOnlyOffersUpdatesItCovers() {
    var ended = licensed
    ended.hasEnded = true
    #expect(ended.limitsUpdates)
    #expect(!licensed.limitsUpdates)
    #expect(!trial.limitsUpdates)

    let releases = [("0.1.2", "2027-01-10"), ("0.1.3", "2027-01-15"), ("0.1.4", "2027-01-16")]
    let newest = ended.newestCovered(releases) { ReleaseDay($0.1) }
    #expect(newest?.0 == "0.1.3")
    #expect(ended.newestCovered([("0.1.4", "2027-01-16")]) { ReleaseDay($0.1) } == nil)
    #expect(ended.newestCovered([("undated", "")]) { ReleaseDay($0.1) } == nil)
  }

  @Test func polarIsAskedOnceADayWhileThereIsAKey() {
    #expect(!licensed.isCheckDue(now: start + day - 1))
    #expect(licensed.isCheckDue(now: start + day))
    #expect(!trial.isCheckDue(now: start))

    var ended = licensed
    ended.hasEnded = true
    #expect(!ended.isCheckDue(now: start + 2 * day))
  }
}

@Suite struct ReleaseDayTests {
  @Test func readsTheDayReleaseShWrites() {
    #expect(ReleaseDay("2027-01-15") == ReleaseDay(containing: start))
    #expect(ReleaseDay("2027-01-14") != ReleaseDay(containing: start))
    #expect(
      ReleaseDay("2027-01-14") ?? ReleaseDay(containing: .distantFuture)
        < ReleaseDay(containing: start))
  }

  @Test func aTimeOfDayDoesNotChangeTheDay() {
    #expect(ReleaseDay(containing: start - 10 * 3_600) == ReleaseDay(containing: start))
    #expect(ReleaseDay(containing: start + 13 * 3_600) == ReleaseDay(containing: start))
    #expect(ReleaseDay(containing: start + 14 * 3_600) != ReleaseDay(containing: start))
  }

  @Test func refusesWhatIsNotADate() {
    #expect(ReleaseDay("") == nil)
    #expect(ReleaseDay("$(DIRBUFF_RELEASE_DATE)") == nil)
    #expect(ReleaseDay("2027-02-31") == nil)
    #expect(ReleaseDay("2027-01") == nil)
  }
}
