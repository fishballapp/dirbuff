import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func folder(_ id: Int64, _ name: String, _ state: BuffState) -> FolderState {
  FolderState(
    id: id, name: name, path: "\(home)/\(name)", location: "~/\(name)", mark: state.mark,
    buffs: [
      BuffRow(
        buff: .temporary, state: state, status: "12 items go tomorrow · 1.3 GB",
        setting: "Older than 14 days, to the Bin")
    ])
}

/// A folder macOS stopped DirBuff reading, as the folder list shows it.
private func lostAccess(_ id: Int64, _ name: String, at lostAt: Date? = nil) -> FolderState {
  FolderState(
    id: id, name: name, path: "\(home)/\(name)", location: "~/\(name)", mark: .needsYou,
    buffs: [
      BuffRow(
        buff: .temporary, state: .needsYou(fix), status: "macOS took away access",
        setting: "Nothing cleared for 3 days")
    ], accessLostAt: lostAt)
}

private let fix = Fix.giveAccess

private func popover(_ folders: [FolderState], licence: Licence = .licensed) -> PopoverState {
  PopoverState(folders: folders, licence: licence, now: now, calendar: calendar)
}

// The fixtures' `now` is 08:00, so the next clean-up is at 09:00, an hour away.

@Suite struct PopoverHeadline {
  @Test func saysHowManyFoldersNeedYou() {
    let one = popover([folder(1, "Projects", .needsYou(fix)), folder(2, "Scratch", .atRest)])
    #expect(one.headline == "1 folder needs you")
    let two = popover([folder(1, "Projects", .needsYou(fix)), folder(2, "Exports", .needsYou(fix))])
    #expect(two.headline == "2 folders need you")
  }

  @Test func saysEverythingElseIsFineBesideAFolderThatNeedsYou() {
    let beside = popover([folder(1, "Projects", .needsYou(fix)), folder(2, "Scratch", .atRest)])
    #expect(beside.subheadline == "Everything else is fine")
    let alone = popover([folder(1, "Projects", .needsYou(fix))])
    #expect(alone.subheadline == nil)
  }

  @Test func leavesOutTheCountdownWhileSomethingClears() {
    let one = popover([folder(1, "Downloads", .working), folder(2, "Scratch", .atRest)])
    #expect(one.headline == "Clearing Downloads")
    #expect(one.subheadline == nil)
    let two = popover([folder(1, "Downloads", .working), folder(2, "Scratch", .working)])
    #expect(two.headline == "Clearing 2 folders")
  }

  @Test func saysAllTheFoldersAreFineWithTheNextCleanUp() {
    let many = popover([folder(1, "Downloads", .atRest), folder(2, "Scratch", .atRest)])
    #expect(many.headline == "All 2 folders are fine")
    #expect(many.subheadline == "Next clean-up in 1 hr")
    let one = popover([folder(1, "Downloads", .atRest)])
    #expect(one.headline == "The folder is fine")
  }

  @Test func saysAFolderIsPausedWhenItCantBeReached() {
    let unreachable = FolderState(
      id: 1, name: "Exports", path: "/Volumes/T7/Exports", location: "T7 Shuttle",
      mark: .paused,
      buffs: [
        BuffRow(
          buff: .temporary, state: .paused, status: "T7 isn't connected",
          setting: "Older than 14 days, to the Bin")
      ])
    #expect(popover([unreachable]).headline == "1 folder is paused")
  }

  @Test func invitesABuffWhenNoFolderHasOne() {
    let state = popover([])
    #expect(state.headline == "No buffed folders yet")
    #expect(state.subheadline == "Right-click a folder in Finder, then DirBuff: Add Buff")
  }

  @Test(arguments: [
    (Licence.trialEnded, "Your trial has ended"),
    (Licence.ended(paidThrough: nil), "Your licence ended before this version came out"),
    (Licence.paused, "DirBuff couldn't check your licence"),
  ])
  func saysWhyEveryBuffIsPaused(licence: Licence, reason: String) {
    let state = popover([folder(1, "Downloads", .paused)], licence: licence)
    #expect(state.headline == "Every buff is paused")
    #expect(state.subheadline == reason)
    #expect(!state.isCleaning)
  }

  @Test func needsYouComesBeforeClearing() {
    let state = popover([folder(1, "Projects", .needsYou(fix)), folder(2, "Downloads", .working)])
    #expect(state.headline == "1 folder needs you")
    #expect(state.isClearing)
  }
}

@Suite struct PopoverCallouts {
  @Test func showsOneCalloutPerFolderThatNeedsYou() {
    let state = popover([
      folder(1, "Projects", .needsYou(fix)), folder(2, "Scratch", .atRest),
      folder(3, "Exports", .needsYou(fix)),
    ])
    #expect(state.needsYou.map(\.id) == [1, 3])
    #expect(state.needsYou.map(\.folderName) == ["Projects", "Exports"])
    #expect(state.needsYou.first?.fix == .giveAccess)
  }

  @Test func givesTheReasonWithHowLongAgoAccessWentAway() {
    let state = popover([lostAccess(1, "Projects", at: now.addingTimeInterval(-3 * oneDay))])
    #expect(state.needsYou.first?.reason == "macOS took away access 3 days ago")
    #expect(state.needsYou.first?.path == "\(home)/Projects")
  }

  @Test func givesTheStatusAloneWhenTheDayIsUnknown() {
    let state = popover([lostAccess(1, "Projects")])
    #expect(state.needsYou.first?.reason == "macOS took away access")
  }

  @Test func hasNoCalloutWhenNothingNeedsYou() {
    #expect(popover([folder(1, "Downloads", .atRest)]).needsYou.isEmpty)
  }

  @Test func reportsClearingWhileItRuns() {
    #expect(popover([folder(1, "Downloads", .working)]).isClearing)
    #expect(!popover([folder(1, "Downloads", .atRest)]).isClearing)
  }
}

@Suite struct PopoverFolderList {
  @Test func keepsTheFoldersInTheOrderTheyWereAdded() {
    let state = popover([folder(3, "Exports", .atRest), folder(1, "Downloads", .atRest)])
    #expect(state.folders.map(\.name) == ["Exports", "Downloads"])
  }

  @Test func leavesOutABuffTakenOffAndAFolderWithNoOtherBuff() {
    let takenOff = FolderState(
      id: 1, name: "Scratch", path: "\(home)/Scratch", location: "~/Scratch", mark: nil,
      buffs: [
        BuffRow(
          buff: .temporary, state: .takenOff(putBackUntil: now), status: "Off · nothing was moved",
          setting: "")
      ])
    let kept = folder(2, "Downloads", .atRest)
    let state = popover([takenOff, kept])
    #expect(state.folders.map(\.name) == ["Downloads"])
  }
}

@Suite struct PopoverGlyph {
  @Test func showsTheMostUrgentStateAcrossFolders() {
    #expect(popover([folder(1, "Downloads", .atRest)]).glyph == .atRest)
    #expect(popover([folder(1, "Downloads", .working), folder(2, "A", .atRest)]).glyph == .working)
    #expect(
      popover([folder(1, "Downloads", .working), folder(2, "Projects", .needsYou(fix))]).glyph
        == .needsYou)
  }

  @Test func leavesAPausedFolderAtRest() {
    #expect(popover([folder(1, "Exports", .paused), folder(2, "A", .atRest)]).glyph == .atRest)
    #expect(popover([folder(1, "Exports", .paused), folder(2, "A", .working)]).glyph == .working)
  }

  @Test func isAtRestWithNoFolders() {
    #expect(popover([]).glyph == .atRest)
  }

  @Test func isTheNeedsYouGlyphOnceCleaningHasStopped() {
    #expect(popover([], licence: .trialEnded).glyph == .needsYou)
    #expect(popover([folder(1, "Downloads", .paused)], licence: .paused).glyph == .needsYou)
  }
}

@Suite struct PopoverFootLine {
  @Test func hasNoLineOnceTheLicenceIsBought() {
    #expect(popover([], licence: .licensed).foot == nil)
  }

  @Test func offersToBuyDuringTheTrial() {
    let foot = popover([], licence: .trial(daysLeft: 9)).foot
    #expect(foot?.lead == "Trial")
    #expect(foot?.rest == " · 9 days left")
    #expect(foot?.buttonTitle == "Buy…")
    #expect(foot?.isPurchase == true)
    #expect(foot?.isWarning == false)
  }

  @Test func makesBuyTheDefaultOnceTheTrialHasEnded() {
    let foot = popover([], licence: .trialEnded).foot
    #expect(foot?.lead == "Trial ended")
    #expect(foot?.rest == "")
    #expect(foot?.isWarning == true)
  }

  @Test func offersToRenewAnEndedLicence() {
    let foot = popover([], licence: .ended(paidThrough: nil)).foot
    #expect(foot?.buttonTitle == "Renew…")
    #expect(foot?.isPurchase == true)
  }

  @Test func offersACheckWhenOffline() {
    let foot = popover([], licence: .paused).foot
    #expect(foot?.buttonTitle == "Check Licence Now")
    #expect(foot?.isPurchase == false)
  }
}
