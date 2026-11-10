import DirBuffCore
import Foundation
import Security
import Testing

@testable import DirBuffKit

/// Tests that use the real Bin and mount disk images. They run only with DIRBUFF_SYSTEM_TESTS=1, on
/// a Mac set aside for it, never on a developer's own.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DIRBUFF_SYSTEM_TESTS"] == "1"))
struct SystemTests {
  let scratch: Scratch
  let engine: Engine
  let temporary: TemporaryBuff
  let binning = TemporarySettings(maxAgeDays: 30, disposal: .bin)
  let later = Date(timeIntervalSinceNow: 31 * day).wholeSeconds

  init() throws {
    scratch = try Scratch()
    engine = Engine(store: try Store.inMemory())
    temporary = TemporaryBuff(engine: engine)
  }

  /// Adds `folder`, makes it Temporary, runs it, and returns the one journal entry the run wrote.
  private func binOnlyItem(in folder: URL) throws -> JournalEntry {
    let folderID = try temporary.addWearing(folder, binning)
    let summary = try temporary.run(folderID: folderID, now: later)
    #expect(summary.failures == 0)
    return try #require(engine.store.journal(folderID: folderID).first)
  }

  @Test func undoPutsABinnedItemBack() throws {
    let file = try scratch.file("a.txt", bytes: 3)
    let entry = try binOnlyItem(in: scratch.url)
    let binned = URL(fileURLWithPath: try #require(entry.binnedPath))
    #expect(!exists(file) && exists(binned))

    try temporary.undo(journalEntryID: try #require(entry.id))

    #expect(exists(file) && !exists(binned))
    #expect(try engine.store.journalEntry(id: try #require(entry.id))?.undoneAt != nil)
    #expect(throws: TemporaryBuff.Failure.alreadyUndone) {
      try temporary.undo(journalEntryID: try #require(entry.id))
    }
  }

  @Test func undoesTwoItemsTheBinRenamedOnAClash() throws {
    let first = try scratch.file("one/a.txt")
    let second = try scratch.file("two/a.txt")
    let entries = try [first, second].map { try binOnlyItem(in: $0.deletingLastPathComponent()) }
    #expect(Set(entries.map(\.binnedPath)).count == 2)

    for entry in entries { try temporary.undo(journalEntryID: try #require(entry.id)) }

    #expect(exists(first) && exists(second))
  }

  @Test func undoNeverOverwritesANewItem() throws {
    try scratch.file("a.txt")
    let entry = try binOnlyItem(in: scratch.url)
    try scratch.file("a.txt")

    let original = try canonicalPath(of: scratch.url) + "/a.txt"
    #expect(throws: TemporaryBuff.Failure.originalPathTaken(original)) {
      try temporary.undo(journalEntryID: try #require(entry.id))
    }
    try FileManager.default.removeItem(atPath: try #require(entry.binnedPath))
  }

  @Test func undoPutsAnItemBackIntoItsRenamedFolder() throws {
    let inbox = try scratch.folder("Inbox")
    try scratch.file("Inbox/a.txt")
    let entry = try binOnlyItem(in: inbox)
    let renamed = scratch.url.appendingPathComponent("Renamed")
    try FileManager.default.moveItem(at: inbox, to: renamed)

    try temporary.undo(journalEntryID: try #require(entry.id))

    #expect(exists(renamed.appendingPathComponent("a.txt")))
  }

  @Test func undoReportsAnItemGoneFromTheBin() throws {
    try scratch.file("a.txt")
    let entry = try binOnlyItem(in: scratch.url)
    let binnedPath = try #require(entry.binnedPath)
    try FileManager.default.removeItem(atPath: binnedPath)

    #expect(throws: TemporaryBuff.Failure.goneFromBin(binnedPath)) {
      try temporary.undo(journalEntryID: try #require(entry.id))
    }
  }

  /// exFAT has no date added and keeps tags in AppleDouble `._` files.
  @Test func worksOnAnExFATDrive() throws {
    let image = scratch.url.appendingPathComponent("drive.dmg").path
    let mountPoint = try scratch.folder("mount").path
    try hdiutil("create", "-size", "64m", "-fs", "ExFAT", "-volname", "DIRBUFFTEST", image)
    try hdiutil("attach", image, "-nobrowse", "-mountpoint", mountPoint)
    defer { try? hdiutil("detach", mountPoint, "-force") }

    let folder = URL(fileURLWithPath: mountPoint).appendingPathComponent("Temp")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    let file = folder.appendingPathComponent("a.txt")
    try Data(count: 1).write(to: file)
    try setModified(modified, of: file)

    let item = try #require(Inventory.items(in: folder).first)
    #expect(item.freshness == modified)

    let entry = try binOnlyItem(in: folder)
    #expect(try #require(entry.binnedPath).contains("/.Trashes/"))
    try temporary.undo(journalEntryID: try #require(entry.id))
    #expect(exists(file))
  }
}

private func hdiutil(_ arguments: String...) throws {
  let process = try Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: arguments)
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    throw HdiutilFailed(arguments: arguments, status: process.terminationStatus)
  }
}

private struct HdiutilFailed: Error {
  var arguments: [String]
  var status: Int32
}

extension SystemTests {
  @Test func theLoginKeychainKeepsAndReplacesTheBackupKey() throws {
    let keychain = LoginKeychain(service: "app.fishball.dirbuff.tests", account: UUID().uuidString)
    defer {
      SecItemDelete(
        [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: keychain.service,
          kSecAttrAccount as String: keychain.account,
        ] as CFDictionary)
    }
    #expect(try keychain.key() == nil)

    try keychain.save("first")
    try keychain.save("second")

    #expect(try keychain.key() == "second")
  }
}
