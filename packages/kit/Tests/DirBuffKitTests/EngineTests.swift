import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// Runs that delete, on folders under the temporary directory. Runs that bin are in SystemTests.
@Suite struct EngineTests {
  let scratch: Scratch
  let engine: Engine
  let deleting = TemporarySettings(maxAgeDays: 30, disposal: .delete)
  /// Far enough ahead that everything the test just wrote is past the Age limit.
  let later = Date(timeIntervalSinceNow: 31 * day).wholeSeconds

  init() throws {
    scratch = try Scratch()
    engine = Engine(store: try Store.inMemory())
  }

  private func addTemporary(
    _ url: URL,
    settings: TemporarySettings = TemporarySettings()
  ) throws -> Folder {
    var folder = try engine.add(url)
    folder.settings = settings
    try engine.store.save(folder)
    try engine.setTemporary(folder, true)
    return folder
  }

  @Test func addingAFolderListsItOnceAndLeavesItPlain() throws {
    let now = Date().wholeSeconds
    let first = try engine.add(scratch.url, now: now)
    #expect(!TemporaryTag.isSet(on: scratch.url))
    #expect(first.settings == TemporarySettings())

    let second = try engine.add(scratch.url, now: now)
    #expect(second == first)
    #expect(try engine.store.folders().count == 1)
  }

  @Test func turningTemporaryOffKeepsTheFolderAndItsSettings() throws {
    var folder = try engine.add(scratch.url)
    folder.settings = deleting
    try engine.store.save(folder)
    let folderID = try #require(folder.id)

    try engine.setTemporary(folder, true, now: later)
    #expect(TemporaryTag.isSet(on: scratch.url))
    var stored = try engine.store.folder(id: folderID)
    #expect(stored?.settings == deleting)
    #expect(stored?.lastRunAt == later)

    try engine.setTemporary(folder, false)
    #expect(!TemporaryTag.isSet(on: scratch.url))
    stored = try engine.store.folder(id: folderID)
    #expect(stored?.settings == deleting)
  }

  @Test func aLicenceEndingUntagsTheFolderUntilItIsSwitchedBackOn() throws {
    let folder = try addTemporary(scratch.url, settings: deleting)
    try engine.turnOffByLicence(folder)
    #expect(!TemporaryTag.isSet(on: scratch.url))
    #expect(try engine.store.folders().map(\.turnedOffByLicence) == [true])

    try engine.setTemporary(folder, true)
    #expect(TemporaryTag.isSet(on: scratch.url))
    #expect(try engine.store.folders().map(\.turnedOffByLicence) == [false])
  }

  @Test func statusRemovesNothing() throws {
    let old = try scratch.file("old", bytes: 10_000)
    let folder = try addTemporary(scratch.url, settings: deleting)
    let status = try engine.status(folderID: try #require(folder.id), now: later)
    #expect(status.dueNow.map(\.item.url.lastPathComponent) == ["old"])
    #expect(status.upcoming.map(\.item.url.lastPathComponent) == ["old"])
    #expect(status.size >= 10_000)
    #expect(exists(old))
  }

  @Test func runRemovesAndJournals() throws {
    let old = try scratch.file("old", bytes: 10_000)
    let id = try #require(addTemporary(scratch.url, settings: deleting).id)

    let result = try engine.run(folderID: id, now: later)

    #expect(!exists(old))
    #expect(result.failures.isEmpty)
    let entry = try #require(result.journal.first)
    #expect(entry.name == "old")
    #expect(entry.disposal == .delete && entry.binnedPath == nil && entry.reasons == [.age])
    let journal = try engine.store.journal(folderID: id)
    #expect(journal == result.journal)
    #expect(try engine.store.folder(id: id)?.lastRunAt == later)
  }

  @Test func runDoesNothingWhileTheFolderIsntTemporary() throws {
    let old = try scratch.file("old")
    var folder = try engine.add(scratch.url)
    folder.settings = deleting
    try engine.store.save(folder)

    #expect(try engine.run(folderID: try #require(folder.id), now: later).journal.isEmpty)
    #expect(exists(old))
  }

  @Test func findsAFolderAfterItIsRenamed() throws {
    let original = try scratch.folder("Inbox")
    try scratch.file("Inbox/old")
    let id = try #require(addTemporary(original, settings: deleting).id)
    let renamed = scratch.url.appendingPathComponent("Renamed")
    try FileManager.default.moveItem(at: original, to: renamed)

    #expect(try engine.run(folderID: id, now: later).journal.count == 1)
    #expect(try engine.store.folder(id: id)?.path == canonicalPath(of: renamed))
  }

  @Test func cannotUndoADeletion() throws {
    try scratch.file("old")
    let id = try #require(addTemporary(scratch.url, settings: deleting).id)
    let entryID = try #require(engine.run(folderID: id, now: later).journal.first?.id)
    #expect(throws: Engine.Failure.deletedPermanently) {
      try engine.undo(journalEntryID: entryID)
    }
  }

  @Test func removingAFolderUntagsAndForgetsIt() throws {
    let folder = try addTemporary(scratch.url, settings: deleting)
    let folderID = try #require(folder.id)
    _ = try engine.store.insert(
      JournalEntry(
        folderID: folderID, disposal: .delete, name: "old", size: 10,
        reasons: [.age], performedAt: later))

    try engine.remove(folder)

    #expect(!TemporaryTag.isSet(on: scratch.url))
    #expect(try engine.store.folders().isEmpty)
    #expect(try engine.store.journal(folderID: folderID).isEmpty)
  }

  @Test func refusesToAddAProtectedFolder() throws {
    #expect(throws: Engine.Failure.protectedFolder) {
      try engine.add(FileManager.default.homeDirectoryForCurrentUser)
    }
  }
}
