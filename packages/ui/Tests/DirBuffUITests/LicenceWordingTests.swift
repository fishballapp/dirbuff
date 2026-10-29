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

@Suite struct SettingsLicence {
  @Test func offersBuyingWhileTheTrialRuns() {
    let section = Licence.trial(daysLeft: 9).settings(key: nil)
    #expect(section.headline == "Your trial ends in 9 days")
    #expect(section.primary == .buy)
    #expect(section.others == [.enterKey])
    #expect(Licence.trial(daysLeft: 1).settings(key: nil).headline == "Your trial ends tomorrow")
    #expect(Licence.trial(daysLeft: 0).settings(key: nil).headline == "Your trial ends today")
  }

  @Test func saysEveryBuffIsPausedOnceTheTrialEnded() {
    let section = Licence.trialEnded.settings(key: nil)
    #expect(section.headline == "Your trial has ended")
    #expect(
      section.detail
        == "Every buff is paused. $10 a year turns them all back on, gets every update, and supports an open source app."
    )
    #expect(section.primary?.title == "Buy for $10 a Year…")
    #expect(section.others.map(\.title) == ["Enter Licence Key…"])
  }

  @Test func offersRenewingAVersionTheLicenceDoesntCover() {
    for paidThrough in [paidThrough, nil] {
      let ended = Licence.ended(paidThrough: paidThrough).settings(key: nil)
      #expect(ended.headline == "Your licence doesn't cover this version")
      #expect(ended.detail == "Renew it to turn every buff back on.")
      #expect(ended.primary?.title == "Renew for $10 a Year…")
      #expect(ended.others == [.enterKey])
    }
  }

  @Test func saysAKeptVersionKeepsWorking() {
    let kept = Licence.kept(paidThrough: paidThrough).settings(key: nil)
    #expect(kept.headline == "This version keeps working for good")
    #expect(kept.detail == "Renew to get every later version.")
    #expect(kept.primary?.title == "Renew for $10 a Year…")
  }

  @Test func offersACheckWhenItCantBeConfirmed() {
    let section = Licence.paused.settings(key: "DIRBUFF-9AD0419A-F40AE9E63D8D")
    #expect(section.headline == "DirBuff couldn't check your licence")
    #expect(section.detail == "Every buff is paused. Check your connection, then try again.")
    #expect(section.primary?.title == "Check Now")
    #expect(section.others == [.deactivate, .manageSubscription])
  }

  @Test func showsTheKeysEndWhenLicensed() {
    let section = Licence.licensed.settings(key: "DIRBUFF-9AD0419A-F40AE9E63D8D")
    #expect(section.headline == "Your licence is active")
    #expect(section.detail == "Key ****-E63D8D")
    #expect(section.primary == nil)
    #expect(section.others == [.deactivate, .manageSubscription])
  }

  @Test func sumsUpTheLicenceAtTheWelcomesFoot() {
    #expect(Licence.trial(daysLeft: 14).welcomeLine == "14-day trial, then $10 a year")
    #expect(Licence.trial(daysLeft: 9).welcomeLine == "Trial · 9 days left, then $10 a year")
    #expect(Licence.trialEnded.welcomeLine == "Trial ended · $10 a year")
    #expect(Licence.licensed.welcomeLine == "Licensed")
  }

  @Test func saysAPausedLicenceCouldntBeChecked() {
    #expect(Licence.paused.line?.text == "DirBuff couldn't check your licence")
    #expect(Licence.paused.status(key: nil) == "DirBuff couldn't check your licence")
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
