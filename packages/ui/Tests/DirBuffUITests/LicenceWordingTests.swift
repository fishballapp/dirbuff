import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

@Suite struct LicenceWording {
  @Test func showsWhereTheLicenceStandsUntilItIsBought() {
    #expect(Licence.trial(daysLeft: 9).line?.text == "Trial · 9 days left")
    #expect(Licence.trial(daysLeft: 1).line?.text == "Trial ends tomorrow")
    #expect(Licence.trial(daysLeft: 0).line?.text == "Trial ends today")
    #expect(Licence.licensed.line == nil)
    #expect(Licence.trialEnded.line?.action == .buy)
    #expect(Licence.ended.line?.action == .buy)
    #expect(Licence.paused.line?.action == .checkNow)
  }

  @Test func showsOnlyTheEndOfTheKey() {
    #expect(
      Licence.licensed.status(key: "DIRBUFF-9AD0419A-F40AE9E63D8D") == "Licensed · ****-E63D8D")
  }

  @Test func refusesTemporaryOnlyWhileTheFoldersArePlain() {
    #expect(Licence.trialEnded.refusal != nil)
    #expect(Licence.ended.refusal != nil)
    #expect(Licence.paused.refusal == nil)
    #expect(Licence.trial(daysLeft: 3).refusal == nil)
  }
}

@Suite struct StoppedCleaning {
  @Test func promisesNothingWhileCleaningIsStopped() {
    let menu = MenuBarState(
      reports: [report(1, dueNow: [item("a")])], journal: [], freeSpace: 50_000_000_000,
      isFinderExtensionOff: false, licence: .paused, now: now, calendar: calendar, binName: "Bin")
    #expect(menu.headline == "Cleaning is paused")
    #expect(menu.subheadline == Licence.paused.whyPaused)
    #expect(menu.forecast.isEmpty)
    #expect(menu.folders.map(\.distanceToGoing) == ["Paused"])
  }

  @Test func stopsInvitingAFirstFolderOnceTheTrialEnded() {
    let menu = MenuBarState(
      reports: [], journal: [], freeSpace: 50_000_000_000, isFinderExtensionOff: false,
      licence: .trialEnded, now: now, calendar: calendar, binName: "Bin")
    #expect(menu.headline == "No Temporary folders")
    #expect(!menu.invitesFirstFolder)
  }

  @Test func refusesTemporaryInTheMainWindowOnceTheLicenceEnded() {
    let main = MainState(
      reports: [report(1, isTagged: false)], journal: [], freeSpace: 50_000_000_000,
      isFinderExtensionOff: false, licence: .ended, now: now, calendar: calendar, binName: "Bin")
    #expect(main.licenceRefusal == Licence.ended.refusal)
  }
}
