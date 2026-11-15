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

  @Test func isQuietUntilTheTrialsLastDays() {
    #expect(Licence.trial(daysLeft: 13).line?.isProminent == false)
    #expect(Licence.trial(daysLeft: 4).line?.isProminent == false)
    #expect(Licence.trial(daysLeft: 3).line?.isProminent == true)
    #expect(Licence.trial(daysLeft: 0).line?.isProminent == true)
    #expect(Licence.trialEnded.line?.isProminent == true)
    #expect(Licence.ended(paidThrough: nil).line?.isProminent == true)
    #expect(Licence.paused.line?.isProminent == true)
    #expect(Licence.kept(paidThrough: paidThrough).line?.isProminent == false)
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
    let section = Licence.trial(daysLeft: 9).settings(key: nil, price: "$10")
    #expect(section.headline == "Your trial ends in 9 days")
    #expect(section.primary == .buy)
    #expect(section.others == [.enterKey])
    #expect(
      Licence.trial(daysLeft: 1).settings(key: nil, price: "$10").headline
        == "Your trial ends tomorrow")
    #expect(
      Licence.trial(daysLeft: 0).settings(key: nil, price: "$10").headline
        == "Your trial ends today")
  }

  @Test func saysEveryBuffIsPausedOnceTheTrialEnded() {
    let section = Licence.trialEnded.settings(key: nil, price: "£10")
    #expect(section.headline == "Your trial has ended")
    #expect(
      section.detail
        == "Every buff is paused. £10 a year turns them all back on, gets every update, and supports an open source app."
    )
    #expect(section.primary.map(section.title) == "Buy for £10 a Year…")
    #expect(section.others.map(section.title) == ["Enter Licence Key…"])
  }

  @Test func offersRenewingAVersionTheLicenceDoesntCover() {
    for paidThrough in [paidThrough, nil] {
      let ended = Licence.ended(paidThrough: paidThrough).settings(key: nil, price: "$10")
      #expect(ended.headline == "Your licence doesn't cover this version")
      #expect(ended.detail == "Renew it to turn every buff back on.")
      #expect(ended.primary.map(ended.title) == "Renew for $10 a Year…")
      #expect(ended.others == [.enterKey])
    }
  }

  @Test func saysAKeptVersionKeepsWorking() {
    let kept = Licence.kept(paidThrough: paidThrough).settings(key: nil, price: "$10")
    #expect(kept.headline == "This version keeps working for good")
    #expect(kept.detail == "Renew to get every later version.")
    #expect(kept.primary.map(kept.title) == "Renew for $10 a Year…")
  }

  @Test func offersACheckWhenItCantBeConfirmed() {
    let section = Licence.paused.settings(key: "DIRBUFF-9AD0419A-F40AE9E63D8D", price: "$10")
    #expect(section.headline == "DirBuff couldn't check your licence")
    #expect(section.detail == "Every buff is paused. Check your connection, then try again.")
    #expect(section.primary.map(section.title) == "Check Now")
    #expect(section.others == [.deactivate, .manageSubscription])
  }

  @Test func showsTheKeysEndWhenLicensed() {
    let section = Licence.licensed.settings(key: "DIRBUFF-9AD0419A-F40AE9E63D8D", price: "$10")
    #expect(section.headline == "Your licence is active")
    #expect(section.detail == "Key ****-E63D8D")
    #expect(section.primary == nil)
    #expect(section.others == [.deactivate, .manageSubscription])
  }

  @Test func sumsUpTheLicenceAtTheWelcomesFoot() {
    #expect(
      Licence.trial(daysLeft: 14).welcomeLine(price: "€10") == "14-day trial, then €10 a year")
    #expect(
      Licence.trial(daysLeft: 9).welcomeLine(price: "$10")
        == "Trial · 9 days left, then $10 a year")
    #expect(Licence.trialEnded.welcomeLine(price: "$10") == "Trial ended · $10 a year")
    #expect(Licence.licensed.welcomeLine(price: "$10") == "Licensed")
  }

  @Test func saysAPausedLicenceCouldntBeChecked() {
    #expect(Licence.paused.line?.text == "DirBuff couldn't check your licence")
    #expect(Licence.paused.status(key: nil) == "DirBuff couldn't check your licence")
  }
}

@Suite struct LocalPrice {
  private let english = Locale(identifier: "en_US")

  private func price(_ timeZone: String, _ locale: Locale) -> String {
    guard let zone = TimeZone(identifier: timeZone) else {
      Issue.record("No time zone \(timeZone)")
      return ""
    }
    return Pricing.yearly(timeZone: zone, locale: locale)
  }

  @Test func quotesPoundsInTheUK() {
    #expect(price("Europe/London", english) == "£10")
    #expect(price("Europe/Jersey", english) == "£10")
  }

  @Test func quotesEurosInTheEurozone() {
    #expect(price("Europe/Paris", english) == "€10")
    #expect(price("Europe/Dublin", english) == "€10")
  }

  @Test func quotesDollarsEverywhereElse() {
    #expect(price("America/New_York", english) == "$10")
    #expect(price("Asia/Hong_Kong", english) == "$10")
    // Switzerland and Sweden aren't in the eurozone: Polar charges them dollars.
    #expect(price("Europe/Zurich", english) == "$10")
    #expect(price("Europe/Stockholm", english) == "$10")
  }

  @Test func writesThePriceTheReadersWay() {
    // The narrow symbol keeps a British reader's dollars "$10", not "US$10".
    #expect(price("America/New_York", Locale(identifier: "en_GB")) == "$10")
    let german = price("Europe/Berlin", Locale(identifier: "de_DE"))
    #expect(german.hasPrefix("10") && german.hasSuffix("€"))
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
