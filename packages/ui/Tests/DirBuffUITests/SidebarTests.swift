import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func sidebar(_ reports: [FolderReport], licence: Licence = .licensed) -> [SidebarFolder] {
  MainState(
    reports: reports, licence: licence, now: now, calendar: calendar, binName: "Bin", home: home,
    startupVolumeName: "Macintosh HD"
  ).sidebarFolders
}

@Suite struct SidebarFolders {
  @Test func sortsAToZAndNeverByState() {
    let rows = sidebar([
      report(1, name: "screenshots"),
      report(2, name: "Downloads"),
      report(3, name: "Projects", problem: .noAccess),
      report(4, name: "Exports 10", path: "\(home)/Exports 10"),
      report(5, name: "Exports 9", path: "\(home)/Exports 9"),
    ])
    #expect(
      rows.map(\.title) == ["Downloads", "Exports 9", "Exports 10", "Projects", "screenshots"])
  }

  @Test func namesTheVolumeOfFoldersThatShareAName() {
    let rows = sidebar([
      report(1, name: "Exports", path: "/Volumes/T7 Shuttle/Exports"),
      report(2, name: "Exports", path: "\(home)/Exports"),
      report(3, name: "Downloads"),
    ])
    #expect(rows.map(\.title) == ["Downloads", "Exports · Macintosh HD", "Exports · T7 Shuttle"])
  }

  @Test func namesTheParentWhenTheVolumeIsShared() {
    let rows = sidebar([
      report(1, name: "Exports", path: "\(home)/Film/Exports"),
      report(2, name: "exports", path: "\(home)/Music/exports"),
      report(3, name: "Exports", path: "/Volumes/T7 Shuttle/Exports"),
    ])
    #expect(rows.map(\.title) == ["Exports · Film", "exports · Music", "Exports · T7 Shuttle"])
  }

  @Test func needsYouWithTheFolder() {
    let rows = sidebar([report(1, name: "Projects", problem: .noAccess), report(2, name: "Notes")])
    #expect(rows.map(\.condition) == [.atRest, .needsYou])
    #expect(rows[1].buffs == [.temporary])
    #expect(rows[1].note == nil)
  }

  @Test func saysAnUnpluggedFolderIsNotConnected() {
    let rows = sidebar([
      report(1, name: "Exports", path: "/Volumes/T7/Exports", problem: .unreachable)
    ])
    #expect(rows.first?.condition == .unplugged)
    #expect(rows.first?.buffs == [.temporary])
    #expect(rows.first?.note == "Not connected")
  }

  @Test func saysAFolderWearingNothingHasNoBuffs() {
    let rows = sidebar([report(1, name: "Scratch", wearsTemporary: false)])
    #expect(rows.first?.buffs == [])
    #expect(rows.first?.condition == .atRest)
    #expect(rows.first?.note == "No buffs")
    #expect(rows.first?.folder.mark == nil)
  }

  @Test func quietensEveryBuffTheLicencePaused() {
    let rows = sidebar(
      [report(1, name: "Downloads", wearsTemporary: false, turnedOffByLicence: true)],
      licence: .trialEnded)
    #expect(rows.first?.condition == .paused)
    #expect(rows.first?.note == nil)
  }
}
