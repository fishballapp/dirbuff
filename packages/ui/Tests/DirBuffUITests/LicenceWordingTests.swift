import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private let paidThrough = Date(timeIntervalSince1970: 1_800_000_000)

@Suite struct LicenceWording {
  @Test func showsWhereTheLicenceStandsUntilItIsBought() {
    #expect(Licence.trial(daysLeft: 9).line?.text == "Trial · 9 days left")
    #expect(Licence.trial(daysLeft: 1).line?.text == "Trial ends tomorrow")
    #expect(Licence.trial(daysLeft: 0).line?.text == "Trial ends today")
    #expect(Licence.licensed.line == nil)
    #expect(Licence.trialEnded.line?.action == .buy)
    #expect(Licence.ended(paidThrough: paidThrough).line?.action == .renew)
    #expect(Licence.kept(paidThrough: paidThrough).line?.action == .renew)
    #expect(Licence.paused.line?.action == .checkNow)
  }

  @Test func asksToBuyFirstAndToRenewAfterwards() {
    #expect(Licence.trial(daysLeft: 3).buyTitle == "Buy…")
    #expect(Licence.trialEnded.buyTitle == "Buy…")
    #expect(Licence.ended(paidThrough: paidThrough).buyTitle == "Renew DirBuff…")
    #expect(Licence.kept(paidThrough: paidThrough).buyTitle == "Renew DirBuff…")
  }

  @Test func saysAKeptVersionKeepsWorking() {
    #expect(
      Licence.kept(paidThrough: paidThrough).status(key: nil).contains("you keep this version"))
    #expect(Licence.kept(paidThrough: paidThrough).refusal == nil)
  }

  @Test func saysWhyALaterVersionWontRun() {
    let ended = Licence.ended(paidThrough: paidThrough)
    #expect(ended.status(key: nil).contains("renew to use this version"))
    #expect(Licence.ended(paidThrough: nil).status(key: nil) == "Licence ended")
  }

  @Test func quotesThePriceInAllThreeCurrencies() {
    #expect(Pricing.yearly == "$10, £10 or €10 a year")
    #expect(Pricing.pitch.contains("open source"))
    #expect(Pricing.pitch.contains("keep the version you have"))
  }

  @Test func showsOnlyTheEndOfTheKey() {
    #expect(
      Licence.licensed.status(key: "DIRBUFF-9AD0419A-F40AE9E63D8D") == "Licensed · ****-E63D8D")
  }

  @Test func refusesTemporaryOnlyWhileTheFoldersArePlain() {
    #expect(
      Licence.trialEnded.refusal
        == "Your trial has ended. Buy DirBuff to make folders Temporary again.")
    #expect(Licence.ended(paidThrough: paidThrough).refusal != nil)
    #expect(Licence.paused.refusal == nil)
    #expect(Licence.trial(daysLeft: 3).refusal == nil)
  }
}

@Suite struct StoppedCleaning {
  @Test func refusesTemporaryInTheMainWindowOnceTheLicenceEnded() {
    let main = MainState(
      reports: [report(1, wearsTemporary: false)],
      licence: .ended(paidThrough: paidThrough), now: now,
      calendar: calendar, binName: "Bin")
    #expect(main.licenceRefusal == Licence.ended(paidThrough: paidThrough).refusal)
    #expect(main.buyTitle == "Renew DirBuff…")
  }
}
