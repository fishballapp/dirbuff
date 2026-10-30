import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func page(_ reports: [FolderReport], licence: Licence = .licensed) -> BuffsPageState {
  MainState(
    reports: reports, licence: licence, now: now, calendar: calendar, binName: "Bin", home: home,
    startupVolumeName: "Macintosh HD"
  ).buffsPage(binName: "Bin")
}

private let reports = [
  report(1, name: "Screenshots"),
  report(2, name: "Downloads"),
  report(3, name: "Scratch", wearsTemporary: false),
  report(4, name: "Library", wearsTemporary: false),
]

@Suite struct BuffsPageCards {
  @Test func listsEveryBuffWithHowManySoon() {
    let state = page(reports)
    #expect(state.cards.map(\.buff) == [.temporary, .backup, .organise, .search])
    #expect(state.subtitle == "4 buffs · 3 soon")
  }

  @Test func namesTheFoldersThatWearABuffAToZ() throws {
    let temporary = try #require(page(reports).cards.first)
    #expect(temporary.folders.map(\.title) == ["Downloads", "Screenshots"])
    #expect(temporary.wornBy == "On 2 folders")
    #expect(page([]).cards.first?.wornBy == "On no folders yet")
    #expect(page([report(1)]).cards.first?.wornBy == "On 1 folder")
  }

  @Test func saysHowTemporaryStarts() {
    let cards = page(reports).cards
    #expect(cards.first?.startsAs == "Default: older than 90 days, to the Bin.")
    #expect(cards.dropFirst().allSatisfy { $0.startsAs == nil })
  }

  @Test func offersTheFoldersThatDontWearIt() throws {
    let temporary = try #require(page(reports).cards.first)
    #expect(
      temporary.targets == [
        AddToFolderItem(
          folderID: 4, title: "Library", isEnabled: false,
          subtitle: "Library is protected. DirBuff never clears it."),
        AddToFolderItem(folderID: 3, title: "Scratch", isEnabled: true, subtitle: nil),
      ])
    #expect(temporary.canAdd)
  }

  @Test func addsNothingSoonOrWhileEveryBuffIsPaused() {
    #expect(page(reports).cards.dropFirst().allSatisfy { !$0.canAdd })
    #expect(page(reports, licence: .trialEnded).cards.allSatisfy { !$0.canAdd })
  }
}
