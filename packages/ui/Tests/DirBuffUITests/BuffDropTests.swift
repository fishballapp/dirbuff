import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func shelf(licence: Licence = .licensed) -> MainState {
  MainState(
    reports: [
      report(1, name: "Downloads"),
      // Added with + Folder, wearing nothing yet.
      report(2, name: "Scratch", wearsTemporary: false),
      report(3, name: "Library", wearsTemporary: false),
    ],
    licence: licence,
    now: now,
    calendar: calendar,
    binName: "Bin",
    home: home,
    startupVolumeName: "Macintosh HD"
  )
}

private func folder(_ name: String, in state: MainState) throws -> FolderState {
  try #require(state.shelfFolders.first { $0.name == name })
}

@Suite struct BuffDropVerdicts {
  private func verdict(_ buff: Buff, on folder: FolderState, in state: MainState)
    -> BuffDropVerdict
  {
    BuffDropVerdict.of(
      buff, on: folder, items: state.addBuffItems(for: folder), mayClean: state.mayClean)
  }

  @Test func aFolderThatCanWearItTakesIt() throws {
    let state = shelf()
    #expect(
      verdict(.temporary, on: try folder("Scratch", in: state), in: state)
        == .add("Add Temporary to Scratch"))
  }

  @Test func aFolderWearingItAlreadySaysSo() throws {
    let state = shelf()
    #expect(
      verdict(.temporary, on: try folder("Downloads", in: state), in: state)
        == .refused("Downloads already wears Temporary"))
  }

  @Test func aProtectedFolderIsProtected() throws {
    let state = shelf()
    #expect(verdict(.temporary, on: try folder("Library", in: state), in: state) == .protected)
  }

  @Test func nothingGoesOnWhileEveryBuffIsPaused() throws {
    let state = shelf(licence: .trialEnded)
    #expect(
      verdict(.temporary, on: try folder("Scratch", in: state), in: state)
        == .refused("Every buff is paused"))
  }

  @Test func aSoonBuffIsRefused() throws {
    let state = shelf()
    #expect(
      verdict(.organise, on: try folder("Scratch", in: state), in: state)
        == .refused("Organise isn't ready yet"))
  }
}

@Suite struct AddedDisposalLine {
  @Test func saysWhereThingsGo() {
    #expect(Disposal.bin.addedLine(binName: "Bin") == "Moved to the Bin")
    #expect(Disposal.bin.addedLine(binName: "Trash") == "Moved to the Trash")
    #expect(Disposal.delete.addedLine(binName: "Bin") == "Deleted permanently")
  }
}

@Suite struct AgeDayChoices {
  @Test func offerTheDefaultInOrder() {
    #expect(
      TemporarySettings.ageDayChoices(including: 90) == [7, 14, 30, 90])
  }

  @Test func keepTheFolderOwnDays() {
    #expect(TemporarySettings.ageDayChoices(including: 45) == [7, 14, 30, 45, 90])
  }

  @Test func offerOnlyTheUsualDaysWhenTheRuleIsAnother() {
    #expect(TemporarySettings.ageDayChoices(including: nil) == [7, 14, 30, 90])
  }
}
