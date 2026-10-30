import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

/// A folder that wears nothing, where DirBuff can't reach it: deleted, or on an unplugged drive.
private let missing = report(3, name: "Scratch", wearsTemporary: false, problem: .missing)
private let unplugged = report(
  4, name: "Exports", path: "/Volumes/T7 Shuttle/Exports", wearsTemporary: false,
  problem: .unreachable)

private func shelf(_ reports: [FolderReport], licence: Licence = .licensed) -> MainState {
  MainState(
    reports: reports, licence: licence, now: now, calendar: calendar, binName: "Bin", home: home,
    startupVolumeName: "Macintosh HD")
}

private func folder(_ id: Int64, in state: MainState) throws -> FolderState {
  try #require(state.shelfFolders.first { $0.id == id })
}

@Suite struct AFolderWearingNothingOutOfReach {
  @Test func keepsItsProblem() throws {
    let state = shelf([report(1, name: "Downloads"), missing, unplugged])
    #expect(try folder(3, in: state).isMissing)
    #expect(try folder(4, in: state).isUnplugged)
    #expect(try folder(1, in: state).problem == nil)
  }

  @Test func needsYouOnceMissing() throws {
    let state = shelf([missing, unplugged])
    #expect(try folder(3, in: state).isNeedingYou)
    #expect(try !folder(4, in: state).isNeedingYou)
    #expect(state.shelfFolders.map(\.id) == [3, 4])
  }

  @Test func readsAsSuchInTheSidebar() {
    let rows = shelf([missing, unplugged]).sidebarFolders
    #expect(rows.map(\.title) == ["Exports", "Scratch"])
    #expect(rows.map(\.condition) == [.unplugged, .needsYou])
    #expect(rows.map(\.note) == ["Not connected", "No buffs"])
  }

  @Test func showsLocateOnItsPage() throws {
    let page = try #require(
      FolderPageState(
        folderID: 3, reports: [missing], shelf: shelf([missing]), now: now, calendar: calendar,
        binName: "Bin", home: home))
    #expect(page.isMissing)
    #expect(page.cards.isEmpty)
  }

  @Test func takesNoBuffFromAMenu() throws {
    let state = shelf([missing, unplugged])
    #expect(
      state.addBuffItems(for: try folder(3, in: state)).first
        == AddBuffItem(buff: .temporary, isEnabled: false, subtitle: "DirBuff can't find Scratch"))
    #expect(
      state.addBuffItems(for: try folder(4, in: state)).first
        == AddBuffItem(buff: .temporary, isEnabled: false, subtitle: "T7 Shuttle isn't connected"))
  }

  @Test func refusesADrop() throws {
    let state = shelf([missing, unplugged])
    func verdict(_ id: Int64) throws -> BuffDropVerdict {
      let target = try folder(id, in: state)
      return BuffDropVerdict.of(
        .temporary, on: target, items: state.addBuffItems(for: target), mayClean: true)
    }
    #expect(try verdict(3) == .refused("DirBuff can't find Scratch"))
    #expect(try verdict(4) == .refused("T7 Shuttle isn't connected"))
  }
}

@Suite struct AFolderWearingNothingInReach {
  @Test func givesItsPlaceWithoutASize() throws {
    let plain = report(1, name: "Scratch", wearsTemporary: false)
    let state = shelf([plain])
    #expect(try folder(1, in: state).location == "~/Scratch")
    let page = try #require(
      FolderPageState(
        folderID: 1, reports: [plain], shelf: state, now: now, calendar: calendar, binName: "Bin",
        home: home))
    // It was never read, so it isn't "Empty" either.
    #expect(page.subtitle == "~/Scratch")
  }

  @Test func leavesTheSubtitleUnpausedWhenNoFolderWearsABuff() {
    let plain = [
      report(1, name: "Scratch", wearsTemporary: false),
      report(2, name: "Music", wearsTemporary: false),
    ]
    #expect(shelf(plain, licence: .trialEnded).shelfSubtitle == "2 folders")
    let worn =
      plain + [report(3, name: "Downloads", wearsTemporary: false, turnedOffByLicence: true)]
    #expect(shelf(worn, licence: .trialEnded).shelfSubtitle == "3 folders · all paused")
  }
}
