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

  @Test func countsFoldersNeedsYouTemporaryAndLocations() {
    let state = mainState([
      report(1, name: "Downloads"),
      report(2, name: "Projects", problem: .noAccess),
      report(3, name: "Screenshots", wearsTemporary: false),
      report(4, name: "Exports", path: "/Volumes/T7 Shuttle/Exports"),
      report(5, name: "Backups", path: "/Volumes/Archive Disk/Backups"),
      report(6, name: "Plain", wearsTemporary: false),
    ])
    // Plain folders, Screenshots taken off among them, aren't on the shelf.
    #expect(state.shelfFolders.count == 4)
    #expect(state.needsYouCount == 1)
    #expect(state.buffCount(.temporary) == 4)
    #expect(state.sidebarBuffs == [.temporary])
    #expect(
      state.locations == [
        ShelfLocation(volumePath: "/", name: "Macintosh HD", isExternal: false, count: 2),
        ShelfLocation(
          volumePath: "/Volumes/Archive Disk", name: "Archive Disk", isExternal: true, count: 1),
        ShelfLocation(
          volumePath: "/Volumes/T7 Shuttle", name: "T7 Shuttle", isExternal: true, count: 1),
      ])
  }

  @Test func filtersBySidebarSectionAndLocation() {
    let state = mainState([
      report(1, name: "Downloads"),
      report(2, name: "Projects", problem: .noAccess),
      report(3, name: "Screenshots", wearsTemporary: false),
      report(4, name: "Exports", path: "/Volumes/T7 Shuttle/Exports"),
    ])
    #expect(state.shelfFolders(matching: .needsYou).map(\.name) == ["Projects"])
    #expect(
      state.shelfFolders(matching: .buff(.temporary)).map(\.name) == [
        "Projects", "Downloads", "Exports",
      ])
    #expect(
      state.shelfFolders(matching: .location("/")).map(\.name) == ["Projects", "Downloads"])
    #expect(
      state.shelfFolders(matching: .location("/Volumes/T7 Shuttle")).map(\.name) == ["Exports"])
    // Unknown or unmounted location falls back to All Folders.
    #expect(state.shelfFolders(matching: .location("/Volumes/Gone")).count == 3)
  }

  @Test func filtersByFolderNamePreservingOrder() {
    let state = mainState([
      report(1, name: "Screen Captures"),
      report(2, name: "Downloads"),
      report(3, name: "Screenshots", problem: .noAccess),
    ])
    #expect(
      state.shelfFolders(matching: .allFolders, query: "  screen ").map(\.name) == [
        "Screenshots", "Screen Captures",
      ])
    #expect(state.shelfFolders(matching: .needsYou, query: "down").isEmpty)
  }

  @Test func hidesNeedsYouAndPausesSubtitleWhenPausedByLicence() {
    let endedReports = [
      report(1, name: "Downloads", wearsTemporary: false, turnedOffByLicence: true),
      report(2, name: "Projects", problem: .noAccess),
      report(3, name: "Screenshots", wearsTemporary: false, turnedOffByLicence: true),
    ]
    let trialEnded = mainState(endedReports, licence: .trialEnded)
    #expect(!trialEnded.showsNeedsYouInSidebar)
    #expect(trialEnded.needsYouCount == 0)
    #expect(trialEnded.buffCount(.temporary) == 3)
    #expect(trialEnded.resolvedFilter(.needsYou) == .allFolders)
    #expect(trialEnded.toolbarSubtitle(for: .allFolders) == "3 folders · all paused")

    let licenceEnded = mainState(
      endedReports, licence: .ended(paidThrough: now.addingTimeInterval(-oneDay)))
    #expect(licenceEnded.toolbarSubtitle(for: .allFolders) == "3 folders · all paused")

    let offlinePaused = mainState([report(1, name: "Downloads")], licence: .paused)
    #expect(offlinePaused.toolbarSubtitle(for: .allFolders) == "1 folder · paused")
  }

  @Test func formatsToolbarCopy() {
    let state = mainState([
      report(1, name: "Downloads"),
      report(2, name: "Projects", problem: .noAccess),
      report(3, name: "Exports", path: "/Volumes/T7 Shuttle/Exports"),
    ])
    #expect(state.toolbarTitle(for: .allFolders) == "Folders")
    #expect(state.toolbarTitle(for: .location("/Volumes/T7 Shuttle")) == "T7 Shuttle")
    #expect(state.toolbarSubtitle(for: .allFolders) == "3 folders · 1 needs you")
    #expect(state.toolbarSubtitle(for: .location("/Volumes/T7 Shuttle")) == "1 folder")

    let twoNeedYou = mainState([
      report(1, name: "Alpha", problem: .noAccess),
      report(2, name: "Beta", problem: .noAccess),
    ])
    #expect(twoNeedYou.toolbarSubtitle(for: .allFolders) == "2 folders · 2 need you")
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
