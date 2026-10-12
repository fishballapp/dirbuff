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

private func licence(_ record: LicenceRecord, after interval: TimeInterval) -> Licence {
  Licence(record, now: start.addingTimeInterval(interval), calendar: calendar)
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

  @Test func noAnswerFromPolarForTheOfflineGracePausesCleaning() {
    #expect(licence(licensed, after: 14 * day) == .paused)
  }

  @Test func aNewAnswerFromPolarResumesCleaning() {
    var record = licensed
    record.lastCheckedAt = start + 20 * day
    #expect(licence(record, after: 20 * day) == .licensed)
  }

  @Test func polarSayingTheLicenceEndedEndsItWhatever() {
    var record = licensed
    record.hasEnded = true
    #expect(licence(record, after: 0) == .ended)
  }

  @Test func onlyTheTrialAndALicenceClean() {
    #expect(Licence.trial(daysLeft: 3).mayClean)
    #expect(Licence.licensed.mayClean)
    #expect(!Licence.trialEnded.mayClean)
    #expect(!Licence.paused.mayClean)
    #expect(!Licence.ended.mayClean)
  }

  @Test func onlyAConfirmedEndMakesFoldersPlain() {
    #expect(Licence.trialEnded.plainsFolders)
    #expect(Licence.ended.plainsFolders)
    #expect(!Licence.paused.plainsFolders)
    #expect(!Licence.trial(daysLeft: 0).plainsFolders)
    #expect(!Licence.licensed.plainsFolders)
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
