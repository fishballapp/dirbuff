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
  /// A fixed day, so the put-back window doesn't depend on when the tests run.
  let takenOff = Date(timeIntervalSince1970: 1_800_000_000)

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

  /// An engine on a database as 0.1.x left it, with a folder for each URL.
  private func upgradedEngine(_ folders: [URL]) throws -> Engine {
    Engine(
      store: try legacyStore(
        try folders.map {
          LegacyFolder(bookmark: try $0.bookmarkData(), path: try canonicalPath(of: $0))
        }))
  }

  @Test func addingAFolderListsItOnceAndLeavesItPlain() throws {
    let now = Date().wholeSeconds
    let first = try engine.add(scratch.url, now: now)
    #expect(!first.wearsTemporary)
    #expect(first.settings == TemporarySettings())

    let second = try engine.add(scratch.url, now: now)
    #expect(second == first)
    #expect(try engine.store.folders().count == 1)
  }

  @Test func turningTemporaryOnAndOffSetsTheDatabaseAndWritesNoTag() throws {
    var folder = try engine.add(scratch.url)
    folder.settings = deleting
    try engine.store.save(folder)
    let folderID = try #require(folder.id)

    try engine.setTemporary(folder, true, now: later)
    var stored = try engine.store.folder(id: folderID)
    #expect(stored?.wearsTemporary == true)
    #expect(stored?.settings == deleting)
    #expect(stored?.lastRunAt == later)
    #expect(try finderTags(of: scratch.url).isEmpty)

    try engine.setTemporary(folder, false, now: later)
    stored = try engine.store.folder(id: folderID)
    #expect(stored?.wearsTemporary == false)
    #expect(stored?.settings == deleting)
    #expect(try finderTags(of: scratch.url).isEmpty)
  }

  @Test func aLicenceEndingStopsTemporaryUntilItIsSwitchedBackOn() throws {
    let folder = try addTemporary(scratch.url, settings: deleting)
    let folderID = try #require(folder.id)

    try engine.turnOffByLicence(folder)
    var stored = try #require(try engine.store.folder(id: folderID))
    #expect(!stored.wearsTemporary && stored.turnedOffByLicence)
    #expect(try finderTags(of: scratch.url).isEmpty)

    try engine.setTemporary(folder, true)
    stored = try #require(try engine.store.folder(id: folderID))
    #expect(stored.wearsTemporary && !stored.turnedOffByLicence)
  }

  @Test func aFolderTakenOffCanBePutBackUntilTheSameTimeTheNextDay() throws {
    let folder = try addTemporary(scratch.url, settings: deleting)
    let folderID = try #require(folder.id)
    #expect(!engine.canPutBack(folder, now: takenOff))

    try engine.setTemporary(folder, false, now: takenOff)
    var stored = try #require(try engine.store.folder(id: folderID))
    #expect(stored.takenOffAt == takenOff)
    #expect(engine.canPutBack(stored, now: takenOff.addingTimeInterval(23 * 3600)))
    #expect(!engine.canPutBack(stored, now: takenOff.addingTimeInterval(25 * 3600)))

    try engine.putBack(stored, now: takenOff.addingTimeInterval(23 * 3600))
    stored = try #require(try engine.store.folder(id: folderID))
    #expect(stored.wearsTemporary)
    #expect(stored.settings == deleting)
  }

  @Test func putBackRefusesAfterTheDay() throws {
    let folder = try addTemporary(scratch.url, settings: deleting)
    let folderID = try #require(folder.id)
    try engine.setTemporary(folder, false, now: takenOff)
    let stored = try #require(try engine.store.folder(id: folderID))

    #expect(throws: Engine.Failure.cannotPutBack) {
      try engine.putBack(stored, now: takenOff.addingTimeInterval(25 * 3600))
    }
    #expect(try engine.store.folder(id: folderID)?.wearsTemporary == false)
  }

  @Test func aLicencePauseEndsThePutBackWindow() throws {
    let folder = try addTemporary(scratch.url, settings: deleting)
    let folderID = try #require(folder.id)
    try engine.setTemporary(folder, false, now: takenOff)
    try engine.setTemporary(folder, true, now: takenOff.addingTimeInterval(3600))
    var stored = try #require(try engine.store.folder(id: folderID))
    #expect(stored.takenOffAt == nil)

    try engine.turnOffByLicence(stored)
    stored = try #require(try engine.store.folder(id: folderID))
    let inTheWindow = takenOff.addingTimeInterval(7200)
    #expect(!engine.canPutBack(stored, now: inTheWindow))
    #expect(throws: Engine.Failure.cannotPutBack) {
      try engine.putBack(stored, now: inTheWindow)
    }

    var paused = stored
    paused.takenOffAt = takenOff
    #expect(!engine.canPutBack(paused, now: inTheWindow))
  }

  @Test func savingSettingsKeepsTheTemporarySwitchMadeSinceTheCopy() throws {
    let folder = try addTemporary(scratch.url, settings: deleting)
    let folderID = try #require(folder.id)
    let copy = try #require(try engine.store.folder(id: folderID))
    try engine.setTemporary(folder, false, now: takenOff)

    let changed = TemporarySettings(maxAgeDays: 7, disposal: .bin)
    try engine.saveSettings(changed, for: copy)

    let stored = try #require(try engine.store.folder(id: folderID))
    #expect(stored.settings == changed)
    #expect(!stored.wearsTemporary)
    #expect(stored.takenOffAt == takenOff)
  }

  @Test func savingSettingsKeepsTheLicencePauseMadeSinceTheCopy() throws {
    let folder = try addTemporary(scratch.url, settings: deleting)
    let folderID = try #require(folder.id)
    let copy = try #require(try engine.store.folder(id: folderID))
    try engine.turnOffByLicence(folder)

    let changed = TemporarySettings(maxAgeDays: 7, disposal: .bin)
    try engine.saveSettings(changed, for: copy)

    let stored = try #require(try engine.store.folder(id: folderID))
    #expect(stored.settings == changed)
    #expect(!stored.wearsTemporary)
    #expect(stored.turnedOffByLicence)
  }

  @Test func choosingEmptyOnRestartCountsFromNow() throws {
    let folder = try addTemporary(scratch.url)
    let folderID = try #require(folder.id)
    let onRestart = TemporarySettings(rule: .emptyOnRestart)

    try engine.saveSettings(onRestart, for: folder, now: takenOff)
    #expect(try engine.store.folder(id: folderID)?.lastRunAt == takenOff)

    try engine.saveSettings(onRestart, for: folder, now: later)
    #expect(try engine.store.folder(id: folderID)?.lastRunAt == takenOff)
  }

  @Test func theLicenceTurnsOffAFolderItCantReach() throws {
    let folder = try addTemporary(scratch.url)
    let folderID = try #require(folder.id)
    try FileManager.default.removeItem(at: scratch.url)

    try engine.turnOffByLicence(folder)
    let stored = try #require(try engine.store.folder(id: folderID))
    #expect(!stored.wearsTemporary)
    #expect(stored.turnedOffByLicence)
  }

  @Test func statusRemovesNothing() throws {
    let old = try scratch.file("old", bytes: 10_000)
    let folder = try addTemporary(scratch.url, settings: deleting)
    let status = try engine.status(folderID: try #require(folder.id), now: later)
    #expect(status.wearsTemporary)
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

  @Test func removingAFolderForgetsItAndItsJournal() throws {
    let folder = try addTemporary(scratch.url, settings: deleting)
    let folderID = try #require(folder.id)
    _ = try engine.store.insert(
      JournalEntry(
        folderID: folderID, disposal: .delete, name: "old", size: 10,
        reasons: [.age], performedAt: later))

    try engine.remove(folder)

    #expect(try engine.store.folders().isEmpty)
    #expect(try engine.store.journal(folderID: folderID).isEmpty)
  }

  @Test func refusesToAddAProtectedFolder() throws {
    #expect(throws: Engine.Failure.protectedFolder) {
      try engine.add(FileManager.default.homeDirectoryForCurrentUser)
    }
  }

  @Test func aFolderFromBeforeThatWasTaggedWearsTemporaryAndLosesItsTag() throws {
    let folder = try scratch.folder("Inbox")
    try setFinderTags([LegacyTemporaryTag.name, "Red"], on: folder)
    let engine = try upgradedEngine([folder])
    let id = try #require(engine.store.folders().first?.id)

    #expect(try engine.status(folderID: id).wearsTemporary)
    #expect(try engine.store.folder(id: id)?.wearsTemporary == true)
    #expect(try finderTags(of: folder) == ["Red"])
    #expect(try !engine.store.hasLegacyTag(folderID: id))
  }

  @Test func anUntaggedFolderFromBeforeIsNotTemporary() throws {
    let folder = try scratch.folder("Downloads")
    let engine = try upgradedEngine([folder])
    let id = try #require(engine.store.folders().first?.id)

    #expect(try !engine.status(folderID: id).wearsTemporary)
    #expect(try engine.store.folder(id: id)?.wearsTemporary == false)
    #expect(try !engine.store.hasLegacyTag(folderID: id))
  }

  @Test func aFolderDIrBuffCantReachStaysPendingAndNothingActsOnIt() throws {
    let folder = try scratch.folder("Drive")
    try setFinderTags([LegacyTemporaryTag.name], on: folder)
    let engine = try upgradedEngine([folder])
    let id = try #require(engine.store.folders().first?.id)
    try FileManager.default.removeItem(at: folder)

    #expect(throws: (any Error).self) { try engine.status(folderID: id) }
    #expect(throws: (any Error).self) {
      try engine.setTemporary(try #require(try engine.store.folder(id: id)), false)
    }
    #expect(try engine.store.hasLegacyTag(folderID: id))
    #expect(try engine.store.folder(id: id)?.wearsTemporary == false)
  }
}
