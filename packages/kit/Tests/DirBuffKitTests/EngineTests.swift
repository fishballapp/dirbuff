import DirBuffCore
import Foundation
import GRDB
import Testing

@testable import DirBuffKit

/// The folder registry, on folders under the temporary directory.
@Suite struct EngineTests {
  let scratch: Scratch
  let engine: Engine
  let temporary: TemporaryBuff
  let deleting = TemporarySettings(maxAgeDays: 30, disposal: .delete)
  /// Far enough ahead that everything the test just wrote is past the Age limit.
  let later = Date(timeIntervalSinceNow: 31 * day).wholeSeconds
  /// A fixed day, so the test doesn't depend on when it runs.
  let takenOff = Date(timeIntervalSince1970: 1_800_000_000)

  init() throws {
    scratch = try Scratch()
    engine = Engine(store: try Store.inMemory())
    temporary = TemporaryBuff(engine: engine)
  }

  @Test func addingAFolderListsItOnceAndLeavesItPlain() throws {
    let now = Date().wholeSeconds
    let first = try engine.add(scratch.url, now: now)
    #expect(try temporary.wear(folderID: try #require(first.id)) == nil)

    let second = try engine.add(scratch.url, now: now)
    #expect(second == first)
    #expect(try engine.store.folders().count == 1)
  }

  @Test func aFolderMovedToABinIsMissingAndNothingActsInIt() throws {
    let inbox = try scratch.folder("Inbox")
    let old = try scratch.file("Inbox/old")
    let id = try temporary.addWearing(inbox, deleting)
    let bin = try scratch.folder(".Trash")
    try FileManager.default.moveItem(at: inbox, to: bin.appendingPathComponent("Inbox"))

    #expect(throws: Engine.Failure.folderMissing) { try temporary.run(folderID: id, now: later) }
    #expect(exists(bin.appendingPathComponent("Inbox/old")))
    #expect(!exists(old))
    #expect(try engine.store.folder(id: id)?.path == canonicalPath(of: inbox))
  }

  @Test func aDeletedFolderIsMissing() throws {
    let inbox = try scratch.folder("Inbox")
    let id = try temporary.addWearing(inbox, deleting)
    try FileManager.default.removeItem(at: inbox)

    #expect(throws: Engine.Failure.folderMissing) { try engine.locate(folderID: id) }
  }

  @Test func locatingAMissingFolderPointsItThereAndClearsMissing() throws {
    let inbox = try scratch.folder("Inbox")
    let id = try temporary.addWearing(inbox, deleting)
    try engine.store.recordMissing(folderID: id, isMissing: true, at: later)
    try FileManager.default.removeItem(at: inbox)
    let found = try scratch.folder("Found")
    try scratch.file("Found/old")

    try engine.relocate(folderID: id, to: found)

    let folder = try #require(try engine.store.folder(id: id))
    #expect(folder.path == (try canonicalPath(of: found)) && folder.missingSince == nil)
    #expect(try temporary.run(folderID: id, now: later).items == 1)
  }

  @Test func locatingRefusesAFolderInABin() throws {
    let id = try temporary.addWearing(try scratch.folder("Inbox"), deleting)
    let binned = try scratch.folder(".Trash/Inbox")

    #expect(throws: Engine.Failure.folderInBin) { try engine.relocate(folderID: id, to: binned) }
  }

  @Test func locatingRefusesAFolderDirBuffAlreadyHas() throws {
    let id = try temporary.addWearing(try scratch.folder("Inbox"), deleting)
    let other = try scratch.folder("Other")
    _ = try engine.add(other)

    #expect(throws: Engine.Failure.folderAlreadyAdded) {
      try engine.relocate(folderID: id, to: other)
    }
  }

  @Test func aNewFolderMadeWhereAMissingOneWasStaysMissing() throws {
    let inbox = try scratch.folder("Inbox")
    let id = try temporary.addWearing(inbox, deleting)
    try FileManager.default.removeItem(at: inbox)
    try engine.store.recordMissing(folderID: id, isMissing: true, at: later)
    let replacement = try scratch.folder("Inbox")
    let precious = try scratch.file("Inbox/precious")

    #expect(throws: Engine.Failure.folderMissing) { try temporary.run(folderID: id, now: later) }
    #expect(exists(precious))
    try engine.relocate(folderID: id, to: replacement)
    #expect(try temporary.run(folderID: id, now: later).items == 1)
  }

  @Test func openingARunDropsRunsLeftEmpty() throws {
    let stale = try engine.store.beginRun(of: .temporary, at: takenOff)
    let fresh = try engine.store.beginRun(of: .temporary, at: later)
    #expect(stale != fresh)
    let runs = try engine.store.database.read {
      try Row.fetchAll($0, sql: "SELECT buff FROM run").map { $0["buff"] as String }
    }
    #expect(runs == [Buff.temporary.rawValue])
  }

  @Test func missingSinceKeepsTheFirstTimeAndClearsOnceFound() throws {
    let id = try temporary.addWearing(scratch.url)
    try engine.store.recordMissing(folderID: id, isMissing: true, at: takenOff)
    try engine.store.recordMissing(folderID: id, isMissing: true, at: later)
    #expect(try engine.store.folder(id: id)?.missingSince == takenOff)
    try engine.store.recordMissing(folderID: id, isMissing: false, at: later)
    #expect(try engine.store.folder(id: id)?.missingSince == nil)
  }

  @Test func findsAFolderAfterItIsRenamed() throws {
    let original = try scratch.folder("Inbox")
    try scratch.file("Inbox/old")
    let id = try temporary.addWearing(original, deleting)
    let renamed = scratch.url.appendingPathComponent("Renamed")
    try FileManager.default.moveItem(at: original, to: renamed)

    #expect(try temporary.run(folderID: id, now: later).items == 1)
    #expect(try engine.store.folder(id: id)?.path == canonicalPath(of: renamed))
  }

  @Test func removingAFolderForgetsItItsBuffsAndItsJournal() throws {
    let folderID = try temporary.addWearing(scratch.url, deleting)
    _ = try engine.store.insert(
      JournalEntry(
        folderID: folderID, disposal: .delete, name: "old", size: 10,
        reasons: [.age], performedAt: later))

    try engine.remove(try #require(try engine.store.folder(id: folderID)))

    #expect(try engine.store.folders().isEmpty)
    #expect(try temporary.wear(folderID: folderID) == nil)
    #expect(try engine.store.journal(folderID: folderID).isEmpty)
  }

  @Test func aFolderWearingNothingIsFoundWithoutBeingRead() throws {
    let plain = try scratch.folder("Plain")
    let id = try #require(try engine.add(plain).id)
    // A folder DirBuff can't list would throw if it were read.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: plain.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.path)
    }
    #expect(try engine.locate(folderID: id).url.path == canonicalPath(of: plain))
    #expect(try temporary.wearers().isEmpty)

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.path)
    try FileManager.default.removeItem(at: plain)
    #expect(throws: Engine.Failure.folderMissing) { try engine.locate(folderID: id) }
  }
}
