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
      mark: .atRest,
      buffs: [
        BuffRow(
          buff: .temporary, state: .paused(.driveUnplugged("T7")), status: "T7 isn't connected",
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
    let state = popover([folder(1, "Downloads", .paused(.licence(.buy)))], licence: licence)
    #expect(state.headline == "Every buff is paused")
    #expect(state.subheadline == reason)
  }

  @Test func needsYouComesBeforeClearing() {
    let state = popover([folder(1, "Projects", .needsYou(fix)), folder(2, "Downloads", .working)])
    #expect(state.headline == "1 folder needs you")
    #expect(state.run == nil)
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

  @Test func saysMacOSTookAwayAccessAsACantClear() {
    let state = popover([lostAccess(1, "Projects", at: now.addingTimeInterval(-3 * oneDay))])
    #expect(state.needsYou.first?.lead == "Can't clear")
  }

  @Test func saysAMissingFolderCantBeFoundAndSinceWhen() {
    let missing = FolderState(
      id: 1, name: "Projects", path: "\(home)/Projects", location: "Was at ~/Projects",
      mark: .needsYou,
      buffs: [
        BuffRow(
          buff: .temporary, state: .needsYou(.locate), status: "Can't find",
          setting: "Missing since Thu 22 Oct, 10:20", statusFolder: "Projects")
      ])
    let callout = popover([missing]).needsYou.first
    #expect(callout?.lead == "Can't find")
    #expect(callout?.reason == "Missing since Thu 22 Oct, 10:20")
    #expect(callout?.fix == .locate)
  }
}

@Suite struct PopoverSchedule {
  /// A folder at rest whose last clean-up ran `ago` seconds before `now`.
  private func ran(_ id: Int64, ago: TimeInterval) -> FolderReport {
    FolderReport(
      folder: Folder(
        id: id, bookmark: Data(), path: "\(home)/Folder\(id)", settings: TemporarySettings(),
        wearsTemporary: true, createdAt: now.addingTimeInterval(-30 * oneDay),
        lastRunAt: now.addingTimeInterval(-ago)),
      reading: .failure(.unreachable))
  }

  private func calm(
    _ folders: [FolderState] = [folder(1, "Downloads", .atRest)], reports: [FolderReport]
  ) -> PopoverState {
    PopoverState(
      folders: folders, reports: reports, licence: .licensed, now: now, calendar: calendar)
  }

  @Test func saysWhenTheLastCleanUpRanAndWhenTheNextIs() {
    // 08:00, so the next clean-up, at 09:00, is in an hour.
    #expect(
      calm(reports: [ran(1, ago: 37 * 60)]).subheadline == "Last clean-up 37 min ago · next in 1 hr"
    )
    #expect(
      calm(reports: [ran(1, ago: 5 * 3_600)]).subheadline == "Last clean-up 5 hr ago · next in 1 hr"
    )
  }

  @Test func usesTheNewestRunAcrossFolders() {
    let state = calm(
      [folder(1, "Downloads", .atRest), folder(2, "Scratch", .atRest)],
      reports: [ran(1, ago: 2 * 3_600), ran(2, ago: 10 * 60)])
    #expect(state.subheadline == "Last clean-up 10 min ago · next in 1 hr")
  }

  @Test func leavesOutAFolderThatWearsNoBuff() {
    // Folder 2 has a report but isn't among the folders that wear a buff.
    let state = calm(
      [folder(1, "Downloads", .atRest)], reports: [ran(1, ago: 2 * 3_600), ran(2, ago: 60)])
    #expect(state.subheadline == "Last clean-up 2 hr ago · next in 1 hr")
  }

  @Test func givesOnlyTheNextCleanUpBeforeAnyHasRun() {
    #expect(calm(reports: []).subheadline == "Next clean-up in 1 hr")
  }

  @Test func sitsUnderAPausedHeadlineToo() {
    let paused = folder(1, "Exports", .paused(.driveUnplugged("T7")))
    let state = calm([paused], reports: [ran(1, ago: 60 * 60)])
    #expect(state.headline == "1 folder is paused")
    #expect(state.subheadline == "Last clean-up 1 hr ago · next in 1 hr")
  }

  @Test func givesWayToTheOtherLinesUnderOtherHeadlines() {
    let needs = calm(
      [folder(1, "Projects", .needsYou(fix)), folder(2, "Scratch", .atRest)],
      reports: [ran(1, ago: 60), ran(2, ago: 60)])
    #expect(needs.subheadline == "Everything else is fine")
    let clearing = calm([folder(1, "Downloads", .working)], reports: [ran(1, ago: 60)])
    #expect(clearing.subheadline == nil)
  }
}

@Suite struct PopoverRunSection {
  private func progress(
    _ folderID: Int64 = 1, done: Int = 3, total: Int = 12, current: String? = "zoom_bundle.zip"
  ) -> Engine.RunProgress {
    Engine.RunProgress(
      folderID: folderID, itemsDone: done, itemsTotal: total, bytesDone: 400_000_000,
      bytesTotal: 1_300_000_000, current: current)
  }

  private func running(_ progress: Engine.RunProgress?) -> PopoverRun? {
    PopoverState(
      folders: [folder(1, "Downloads", .working), folder(2, "Scratch", .atRest)],
      progress: progress, licence: .licensed, now: now, calendar: calendar
    ).run
  }

  @Test func hasNoRunWhileNothingClears() {
    #expect(popover([folder(1, "Downloads", .atRest)]).run == nil)
  }

  @Test func showsTheItemGoingAndHowFarTheRunHasGot() {
    let run = running(progress())
    #expect(run?.folderName == "Downloads")
    #expect(run?.path == "\(home)/Downloads")
    #expect(run?.current == "zoom_bundle.zip")
    #expect(run?.counts == "3 of 12 items · 1.3 GB")
    #expect(run?.fraction == 0.25)
  }

  @Test func countsASingleItem() {
    #expect(running(progress(done: 0, total: 1))?.counts?.hasPrefix("0 of 1 item ·") == true)
  }

  @Test func showsTheFolderBeforeTheEngineHasReported() {
    let run = running(nil)
    #expect(run?.folderName == "Downloads")
    #expect(run?.current == nil)
    #expect(run?.counts == nil)
    #expect(run?.fraction == 0)
  }

  @Test func ignoresAReportForAFolderThatIsntClearing() {
    let run = running(progress(2))
    #expect(run?.folderName == "Downloads")
    #expect(run?.counts == nil)
  }

  @Test func leavesTheBarEmptyForARunWithNothingToClear() {
    let run = running(progress(done: 0, total: 0, current: nil))
    #expect(run?.fraction == 0)
    #expect(run?.counts?.hasPrefix("0 of 0 items ·") == true)
  }

  @Test func yieldsToAFolderThatNeedsYou() {
    let state = popover([folder(1, "Projects", .needsYou(fix)), folder(2, "Downloads", .working)])
    #expect(state.run == nil)
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
    #expect(
      popover([folder(1, "Exports", .paused(.driveUnplugged("T7"))), folder(2, "A", .atRest)]).glyph
        == .atRest)
    #expect(
      popover([folder(1, "Exports", .paused(.driveUnplugged("T7"))), folder(2, "A", .working)])
        .glyph == .working)
  }

  @Test func isAtRestWithNoFolders() {
    #expect(popover([]).glyph == .atRest)
  }

  @Test func isTheNeedsYouGlyphOnceCleaningHasStopped() {
    #expect(popover([], licence: .trialEnded).glyph == .needsYou)
    #expect(
      popover([folder(1, "Downloads", .paused(.licence(.buy)))], licence: .paused).glyph
        == .needsYou)
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
