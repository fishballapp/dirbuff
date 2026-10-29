import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func shelf(licence: Licence = .licensed) -> MainState {
  MainState(
    reports: [
      report(1, name: "Downloads")
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

/// A plain folder, as one wearing another buff would be on the shelf.
private let scratch = FolderState(
  id: 2, name: "Scratch", path: "\(home)/Scratch", location: "~/Scratch", mark: nil, buffs: [])

private let library = FolderState(
  id: 99, name: "Library", path: "\(home)/Library", location: "~/Library", mark: .atRest, buffs: [])

@Suite struct AddBuffRows {
  @Test func withNoTargetTheBuffsOnlyDrag() {
    #expect(
      AddBuffRow.all(for: nil) == [
        AddBuffRow(buff: .temporary, offer: .dragOnly),
        AddBuffRow(buff: .backup, offer: .soon),
        AddBuffRow(buff: .organise, offer: .soon),
        AddBuffRow(buff: .search, offer: .soon),
      ])
  }

  @Test func aBuffTheTargetWearsIsAdded() throws {
    let state = shelf()
    let rows = AddBuffRow.all(for: state.addBuffTarget(try folder("Downloads", in: state)))
    #expect(rows.first == AddBuffRow(buff: .temporary, offer: .added))
  }

  @Test func aBuffTheTargetCanWearIsAddedToIt() {
    let rows = AddBuffRow.all(for: shelf().addBuffTarget(scratch))
    #expect(rows.first == AddBuffRow(buff: .temporary, offer: .add(folderName: "Scratch")))
  }

  @Test func aProtectedTargetOnlyTakesDrags() {
    let rows = AddBuffRow.all(for: shelf().addBuffTarget(library))
    #expect(rows.first == AddBuffRow(buff: .temporary, offer: .dragOnly))
  }

  @Test func onlyAvailableBuffsDrag() {
    #expect(AddBuffRow.all(for: nil).filter(\.isDraggable).map(\.buff) == [.temporary])
  }
}

@Suite struct BuffDropVerdicts {
  private func verdict(_ buff: Buff, on folder: FolderState, in state: MainState)
    -> BuffDropVerdict
  {
    BuffDropVerdict.of(
      buff, on: folder, items: state.addBuffItems(for: folder), mayClean: state.mayClean)
  }

  @Test func aFolderThatCanWearItTakesIt() {
    #expect(verdict(.temporary, on: scratch, in: shelf()) == .add("Add Temporary to Scratch"))
  }

  @Test func aFolderWearingItAlreadySaysSo() throws {
    let state = shelf()
    #expect(
      verdict(.temporary, on: try folder("Downloads", in: state), in: state)
        == .refused("Temporary is already on Downloads"))
  }

  @Test func aProtectedFolderIsProtected() {
    #expect(verdict(.temporary, on: library, in: shelf()) == .protected)
  }

  @Test func nothingGoesOnWhileEveryBuffIsPaused() {
    #expect(
      verdict(.temporary, on: scratch, in: shelf(licence: .trialEnded))
        == .refused("Every buff is paused"))
  }

  @Test func aSoonBuffIsRefused() {
    #expect(verdict(.organise, on: scratch, in: shelf()) == .refused("Organise isn't ready yet"))
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
