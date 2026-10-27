import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private let gigabytes: Int64 = 2_300_000_000

private func entry(
  _ id: Int64,
  _ disposal: Disposal = .bin,
  size: Int64 = gigabytes,
  undone: Bool = false
) -> JournalEntry {
  JournalEntry(
    id: id,
    folderID: 1,
    disposal: disposal,
    name: "item\(id)",
    binnedPath: disposal == .bin ? "\(home)/.Trash/item\(id)" : nil,
    size: size,
    reasons: [.age],
    performedAt: now,
    undoneAt: undone ? now : nil
  )
}

private func notification(
  _ folders: [CleanUpFolder],
  binName: String = "Bin"
) -> CleanUpNotification? {
  CleanUpNotification(folders: folders, binName: binName)
}

@Suite struct CleanUpWording {
  @Test func oneItemBinned() {
    let note = notification([
      CleanUpFolder(path: "\(home)/Downloads", entries: [entry(1, size: 40_000)])
    ])
    #expect(note?.title == "Downloads")
    #expect(note?.body == "1 item went to the Bin · 40 kB")
  }

  @Test func severalItemsBinned() {
    let note = notification([
      CleanUpFolder(
        path: "\(home)/Downloads",
        entries: (1...5).map { entry(Int64($0), size: 460_000_000) }
      )
    ])
    #expect(note?.title == "Downloads")
    #expect(note?.body == "5 items went to the Bin · \(bytes(2_300_000_000))")
  }

  @Test func usesTheSystemsTrashName() {
    let note = notification(
      [CleanUpFolder(path: "\(home)/Downloads", entries: [entry(1, size: 1_000)])],
      binName: "Trash"
    )
    #expect(note?.body == "1 item went to the Trash · \(bytes(1_000))")
  }

  @Test func oneItemDeletedPermanently() {
    let note = notification([
      CleanUpFolder(path: "\(home)/Scratch", entries: [entry(1, .delete, size: 40_000)])
    ])
    #expect(note?.title == "Scratch")
    #expect(note?.body == "1 item was deleted permanently · 40 kB")
  }

  @Test func severalItemsDeletedPermanently() {
    let note = notification([
      CleanUpFolder(path: "\(home)/Scratch", entries: (1...5).map { entry(Int64($0), .delete) })
    ])
    #expect(note?.title == "Scratch")
    #expect(note?.body == "5 items were deleted permanently · 11.5 GB")
  }

  @Test func someBinnedAndSomeDeleted() {
    let note = notification([
      CleanUpFolder(
        path: "\(home)/Downloads",
        entries: [entry(1), entry(2), entry(3, .delete), entry(4, .delete), entry(5, .delete)]
      )
    ])
    #expect(note?.body == "2 items went to the Bin, 3 items were deleted permanently · 11.5 GB")
  }

  @Test func twoFoldersNameBothInStoreOrderAndOpenTheFirst() {
    let note = notification([
      CleanUpFolder(path: "\(home)/Downloads", entries: [entry(1), entry(2)]),
      CleanUpFolder(path: "\(home)/Screenshots", entries: [entry(3, .delete)]),
    ])
    #expect(note?.title == "Downloads and Screenshots")
    #expect(note?.body == "2 items went to the Bin, 1 item was deleted permanently · 6.9 GB")
    #expect(note?.folderPath == "\(home)/Downloads")
  }

  @Test func threeOrMoreFoldersNameFirstTwoAndCountTheRest() {
    let three = notification([
      CleanUpFolder(path: "\(home)/Downloads", entries: [entry(1)]),
      CleanUpFolder(path: "\(home)/Screenshots", entries: [entry(2)]),
      CleanUpFolder(path: "\(home)/Scratch", entries: [entry(3)]),
    ])
    #expect(three?.title == "Downloads, Screenshots and 1 more")
    #expect(three?.folderPath == "\(home)/Downloads")

    let four = notification([
      CleanUpFolder(path: "\(home)/Downloads", entries: [entry(1)]),
      CleanUpFolder(path: "\(home)/Screenshots", entries: [entry(2)]),
      CleanUpFolder(path: "\(home)/Scratch", entries: [entry(3)]),
      CleanUpFolder(path: "\(home)/Desktop", entries: [entry(4)]),
    ])
    #expect(four?.title == "Downloads, Screenshots and 2 more")
    #expect(four?.folderPath == "\(home)/Downloads")
  }

  @Test func foldersThatMovedNothingAreLeftOut() {
    let note = notification([
      CleanUpFolder(path: "\(home)/Desktop", entries: []),
      CleanUpFolder(path: "\(home)/Downloads", entries: [entry(1)]),
    ])
    #expect(note?.title == "Downloads")
    #expect(note?.folderPath == "\(home)/Downloads")
  }

  @Test func nothingMovedMeansNoNotification() {
    #expect(notification([]) == nil)
    #expect(notification([CleanUpFolder(path: "\(home)/Downloads", entries: [])]) == nil)
  }
}

@Suite struct CleanUpPutBack {
  @Test func offeredWhenSomethingWentToTheBin() {
    let note = notification([
      CleanUpFolder(path: "\(home)/Downloads", entries: [entry(7), entry(8)])
    ])
    #expect(note?.canPutBack == true)
    #expect(note?.putBackEntryIDs == [7, 8])
    #expect(note?.actions == [.putBack, .show])
    #expect(note?.actions.map(\.title) == ["Put Back", "Show"])
    #expect(note?.category == .withPutBack)
  }

  @Test func notOfferedWhenEverythingWasDeleted() {
    let note = notification([
      CleanUpFolder(path: "\(home)/Scratch", entries: [entry(7, .delete), entry(8, .delete)])
    ])
    #expect(note?.canPutBack == false)
    #expect(note?.putBackEntryIDs == [])
    #expect(note?.actions == [.show])
    #expect(note?.category == .showOnly)
  }

  @Test func putBackCoversOnlyWhatWentToTheBin() {
    let note = notification([
      CleanUpFolder(
        path: "\(home)/Downloads",
        entries: [entry(1), entry(2, .delete), entry(3)]
      )
    ])
    #expect(note?.putBackEntryIDs == [1, 3])
  }

  @Test func skipsEntriesAlreadyPutBack() {
    let note = notification([
      CleanUpFolder(path: "\(home)/Downloads", entries: [entry(1, undone: true), entry(2)])
    ])
    #expect(note?.putBackEntryIDs == [2])
  }

  @Test func roundTripsUserInfoThroughNSNumberBridging() {
    let note = notification([
      CleanUpFolder(path: "\(home)/Scratch", entries: [entry(10), entry(20)])
    ])
    guard let userInfo = note?.userInfo else {
      Issue.record("Expected notification userInfo")
      return
    }
    #expect(CleanUpNotification.folderPath(from: userInfo) == "\(home)/Scratch")
    #expect(CleanUpNotification.putBackEntryIDs(from: userInfo) == [10, 20])

    let bridged: [AnyHashable: Any] = [
      "folderPath": "\(home)/Scratch",
      "putBackEntryIDs": [NSNumber(value: 10), NSNumber(value: 20)],
    ]
    #expect(CleanUpNotification.putBackEntryIDs(from: bridged) == [10, 20])
  }
}
