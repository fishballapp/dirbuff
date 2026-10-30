import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func mainState(
  _ reports: [FolderReport],
  licence: Licence = .licensed,
  working: Set<Int64> = []
) -> MainState {
  MainState(
    reports: reports,
    licence: licence,
    working: working,
    now: now,
    calendar: calendar,
    binName: "Bin",
    home: home,
    startupVolumeName: "Macintosh HD"
  )
}

@Suite struct MainStateMapping {
  @Test func folderThatIsOffReadsOff() {
    let state = mainState([report(1, wearsTemporary: false)])
    #expect(state.folders.count == 1)
    let folder = state.folders[0]
    #expect(!folder.isTemporary)
    #expect(folder.isReadable)
  }

  @Test func unreadableReadsCantReadThisFolder() {
    let state = mainState([report(1, problem: .unreachable)])
    #expect(state.folders.count == 1)
    let folder = state.folders[0]
    #expect(!folder.isReadable)
    #expect(!folder.isTemporary)
    #expect(folder.preview.headline == "Can't read this folder")
    #expect(folder.preview.forecast.isEmpty)
  }

  @Test func detailFoldersKeepReportOrder() {
    let reports = [
      report(10, name: "Charlie"),
      report(2, name: "Alpha"),
      report(5, name: "Bravo"),
    ]
    let state = mainState(reports)
    #expect(state.folders.map(\.id) == [10, 2, 5])
    #expect(state.folders.map(\.name) == ["Charlie", "Alpha", "Bravo"])
  }

  @Test func mapsSettings() {
    let settings = TemporarySettings(maxAgeDays: 14, disposal: .delete)
    let state = mainState([
      report(1, settings, wearsTemporary: true)
    ])
    #expect(state.folders[0].isTemporary)
    #expect(state.folders[0].settings == settings)
  }
}

@Suite struct ShelfModel {
  @Test func ordersNeedsYouFirstThenByName() {
    let state = mainState([
      report(1, name: "Screenshots"),
      report(2, name: "Downloads"),
      report(3, name: "Projects", problem: .noAccess),
      report(4, name: "Exports", path: "/Volumes/T7 Shuttle/Exports"),
      report(5, name: "Archive", problem: .noAccess),
    ])
    #expect(
      state.shelfFolders.map(\.name) == [
        "Archive", "Projects", "Downloads", "Exports", "Screenshots",
      ])
  }

  @Test func keepsAFolderThatWearsNothing() {
    let state = mainState([
      report(1, name: "Downloads"),
      report(2, name: "Projects", problem: .noAccess),
      report(3, name: "Scratch", wearsTemporary: false),
    ])
    #expect(state.shelfFolders.map(\.name) == ["Projects", "Downloads", "Scratch"])
    let scratch = state.shelfFolders[2]
    #expect(scratch.buffs.isEmpty)
    #expect(scratch.mark == nil)
    #expect(state.needsYouCount == 1)
  }

  @Test func filtersByFolderNamePreservingOrder() {
    let state = mainState([
      report(1, name: "Screen Captures"),
      report(2, name: "Downloads"),
      report(3, name: "Screenshots", problem: .noAccess),
    ])
    #expect(
      state.shelfFolders(matching: "  screen ").map(\.name) == ["Screenshots", "Screen Captures"])
    #expect(state.shelfFolders(matching: "").count == 3)
  }

  @Test func pausesTheSubtitleWhenPausedByLicence() {
    let endedReports = [
      report(1, name: "Downloads", wearsTemporary: false, turnedOffByLicence: true),
      report(2, name: "Projects", problem: .noAccess),
      report(3, name: "Screenshots", wearsTemporary: false, turnedOffByLicence: true),
    ]
    let trialEnded = mainState(endedReports, licence: .trialEnded)
    #expect(trialEnded.needsYouCount == 0)
    #expect(trialEnded.shelfSubtitle == "3 folders · all paused")

    let licenceEnded = mainState(
      endedReports, licence: .ended(paidThrough: now.addingTimeInterval(-oneDay)))
    #expect(licenceEnded.shelfSubtitle == "3 folders · all paused")

    let offlinePaused = mainState([report(1, name: "Downloads")], licence: .paused)
    #expect(offlinePaused.shelfSubtitle == "1 folder · paused")
  }

  @Test func formatsTheSubtitle() {
    let state = mainState([
      report(1, name: "Downloads"),
      report(2, name: "Projects", problem: .noAccess),
      report(3, name: "Exports", path: "/Volumes/T7 Shuttle/Exports"),
    ])
    #expect(state.shelfSubtitle == "3 folders · 1 needs you")

    let twoNeedYou = mainState([
      report(1, name: "Alpha", problem: .noAccess),
      report(2, name: "Beta", problem: .noAccess),
    ])
    #expect(twoNeedYou.shelfSubtitle == "2 folders · 2 need you")
    #expect(mainState([]).shelfSubtitle == "No folders")
  }

  @Test func buildsAddBuffMenuForWornPlainAndProtectedFolders() {
    let state = mainState([
      report(1, name: "Downloads"),
      report(2, name: "Screenshots", wearsTemporary: false),
    ])
    let downloads = state.shelfFolders.first { $0.name == "Downloads" }!
    // Downloads already wears Temporary, so only Soon buffs remain.
    #expect(
      state.addBuffItems(for: downloads) == [
        AddBuffItem(buff: .backup, isEnabled: false, subtitle: "Soon"),
        AddBuffItem(buff: .organise, isEnabled: false, subtitle: "Soon"),
        AddBuffItem(buff: .search, isEnabled: false, subtitle: "Soon"),
      ])

    let library = FolderState(
      id: 99,
      name: "Library",
      path: "\(home)/Library",
      location: "~/Library",
      mark: .atRest,
      buffs: []
    )
    #expect(
      state.addBuffItems(for: library).first
        == AddBuffItem(
          buff: .temporary,
          isEnabled: false,
          subtitle: "Library is protected. DirBuff never clears it."))
    let desktop = FolderState(
      id: 98, name: "Desktop", path: "\(home)/Desktop", location: "~/Desktop", mark: .atRest,
      buffs: [])
    #expect(
      state.addBuffItems(for: desktop).first == AddBuffItem(buff: .temporary, isEnabled: true))
  }
}
