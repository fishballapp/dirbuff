import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func mainState(_ reports: [FolderReport], journal: [JournalEntry] = []) -> MainState {
  MainState(
    reports: reports, journal: journal, freeSpace: 50_000_000_000, isFinderExtensionOff: false,
    licence: .licensed, now: now, calendar: calendar, binName: "Bin")
}

@Suite struct MainStateMapping {
  @Test func folderThatIsOffReadsOff() {
    let state = mainState([report(1, wearsTemporary: false)])
    #expect(state.folders.count == 1)
    let folder = state.folders[0]
    #expect(!folder.isTemporary)
    #expect(folder.isReadable)
    #expect(folder.distanceToGoing == "Off")
  }

  @Test func unreadableReadsCantReadThisFolder() {
    let state = mainState([report(1, problem: .unreachable)])
    #expect(state.folders.count == 1)
    let folder = state.folders[0]
    #expect(!folder.isReadable)
    #expect(!folder.isTemporary)
    #expect(folder.distanceToGoing == "Can't read this folder")
    #expect(folder.preview.headline == "Can't read this folder")
    #expect(folder.preview.forecast.isEmpty)
  }

  @Test func orderFollowsReports() {
    let reports = [
      report(10, name: "Charlie"),
      report(2, name: "Alpha"),
      report(5, name: "Bravo"),
    ]
    let state = mainState(reports)
    #expect(state.folders.map(\.id) == [10, 2, 5])
    #expect(state.folders.map(\.name) == ["Charlie", "Alpha", "Bravo"])
  }

  @Test func menuBarStateLeavesOutFoldersThatAreOff() {
    let reports = [
      report(1, name: "On1", wearsTemporary: true),
      report(2, name: "Off", wearsTemporary: false),
      report(3, name: "On2", wearsTemporary: true),
      report(4, name: "Unreadable", problem: .unreachable),
    ]
    let state = mainState(reports)
    #expect(state.folders.count == 4)
    #expect(state.overview.folders.map(\.name) == ["On1", "On2", "Unreadable"])
    #expect(state.overview.folders.count == 3)
  }

  @Test func mapsSettings() {
    let settings = TemporarySettings(maxAgeDays: 14, disposal: .delete)
    let state = mainState([
      report(1, settings, wearsTemporary: true)
    ])
    #expect(state.folders[0].isTemporary)
    #expect(state.folders[0].settings == settings)
  }

  @Test func showsDistanceForTemporaryFolder() {
    let state = mainState([
      report(1, dueNow: [item("a")]),
      report(2, upcoming: [(item("b"), 2 * oneDay)]),
    ])
    #expect(
      state.folders[0].distanceToGoing
        == "1 item goes in 1 hr")
    #expect(state.folders[1].distanceToGoing == "Oldest goes in 2 days")
  }
}
