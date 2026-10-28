import DirBuffCore
import Foundation
import GRDB
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
    #expect(stored?.settings == TemporarySettings())
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

  @Test func takingTemporaryOffForgetsItsSettings() throws {
    let folder = try addTemporary(scratch.url, settings: deleting)
    try engine.setTemporary(folder, false, now: takenOff)
    try engine.setTemporary(folder, true, now: takenOff)

    let folderID = try #require(folder.id)
    let stored = try #require(try engine.store.folder(id: folderID))
    #expect(stored.wearsTemporary && stored.settings == TemporarySettings())
  }

  @Test func aLicencePauseKeepsTheSettingsForTurningBackOn() throws {
    let folder = try addTemporary(scratch.url, settings: deleting)
    try engine.turnOffByLicence(folder)
    try engine.setTemporary(folder, true, now: takenOff)

    let folderID = try #require(folder.id)
    let stored = try #require(try engine.store.folder(id: folderID))
    #expect(stored.settings == deleting)
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

  @Test func runJournalsUnderItsRunAndReportsProgress() throws {
    try scratch.file("a", bytes: 100)
    try scratch.file("b", bytes: 300)
    let id = try #require(addTemporary(scratch.url, settings: deleting).id)
    let runID = try engine.store.beginRun(at: later)
    var reports: [Engine.RunProgress] = []

    let result = try engine.run(folderID: id, now: later, runID: runID) { reports.append($0) }

    #expect(result.journal.allSatisfy { $0.runID == runID })
    #expect(reports.map(\.itemsDone) == [0, 1, 2])
    #expect(reports.map(\.itemsTotal) == [2, 2, 2])
    // Sizes are what the files take on disk, so whole blocks.
    let last = try #require(reports.last)
    #expect(last.bytesDone == last.bytesTotal && last.bytesTotal >= 400)
    #expect(reports.dropLast().allSatisfy { $0.current != nil } && reports.last?.current == nil)
  }

  @Test func aRunThatRemovedNothingIsDropped() throws {
    try scratch.file("old")
    let id = try #require(addTemporary(scratch.url, settings: deleting).id)
    let empty = try engine.store.beginRun(at: later)
    try engine.store.dropRunIfEmpty(id: empty)
    let full = try engine.store.beginRun(at: later)
    _ = try engine.run(folderID: id, now: later, runID: full)
    try engine.store.dropRunIfEmpty(id: full)

    #expect(try engine.store.journal(folderID: id).first?.runID == full)
  }

  @Test func aFolderMovedToABinIsMissingAndNothingActsInIt() throws {
    let inbox = try scratch.folder("Inbox")
    let old = try scratch.file("Inbox/old")
    let id = try #require(addTemporary(inbox, settings: deleting).id)
    let bin = try scratch.folder(".Trash")
    try FileManager.default.moveItem(at: inbox, to: bin.appendingPathComponent("Inbox"))

    #expect(throws: Engine.Failure.folderMissing) { try engine.run(folderID: id, now: later) }
    #expect(exists(bin.appendingPathComponent("Inbox/old")))
    #expect(!exists(old))
    #expect(try engine.store.folder(id: id)?.path == canonicalPath(of: inbox))
  }

  @Test func aDeletedFolderIsMissing() throws {
    let inbox = try scratch.folder("Inbox")
    let id = try #require(addTemporary(inbox, settings: deleting).id)
    try FileManager.default.removeItem(at: inbox)

    #expect(throws: Engine.Failure.folderMissing) { try engine.status(folderID: id) }
  }

  @Test func locatingAMissingFolderPointsItThereAndClearsMissing() throws {
    let inbox = try scratch.folder("Inbox")
    let id = try #require(addTemporary(inbox, settings: deleting).id)
    try engine.store.recordMissing(folderID: id, isMissing: true, at: later)
    try FileManager.default.removeItem(at: inbox)
    let found = try scratch.folder("Found")
    try scratch.file("Found/old")

    try engine.relocate(folderID: id, to: found)

    let folder = try #require(try engine.store.folder(id: id))
    #expect(folder.path == (try canonicalPath(of: found)) && folder.missingSince == nil)
    #expect(try engine.run(folderID: id, now: later).journal.count == 1)
  }

  @Test func locatingRefusesAFolderInABin() throws {
    let id = try #require(addTemporary(try scratch.folder("Inbox"), settings: deleting).id)
    let binned = try scratch.folder(".Trash/Inbox")

    #expect(throws: Engine.Failure.folderInBin) { try engine.relocate(folderID: id, to: binned) }
  }

  @Test func locatingRefusesAFolderDirBuffAlreadyHas() throws {
    let id = try #require(addTemporary(try scratch.folder("Inbox"), settings: deleting).id)
    let other = try scratch.folder("Other")
    _ = try engine.add(other)

    #expect(throws: Engine.Failure.folderAlreadyAdded) {
      try engine.relocate(folderID: id, to: other)
    }
  }

  @Test func aNewFolderMadeWhereAMissingOneWasStaysMissing() throws {
    let inbox = try scratch.folder("Inbox")
    let id = try #require(addTemporary(inbox, settings: deleting).id)
    try FileManager.default.removeItem(at: inbox)
    try engine.store.recordMissing(folderID: id, isMissing: true, at: later)
    let replacement = try scratch.folder("Inbox")
    let precious = try scratch.file("Inbox/precious")

    #expect(throws: Engine.Failure.folderMissing) { try engine.run(folderID: id, now: later) }
    #expect(exists(precious))
    try engine.relocate(folderID: id, to: replacement)
    #expect(try engine.run(folderID: id, now: later).journal.count == 1)
  }

  @Test func takingOffAMissingFolderWorks() throws {
    let inbox = try scratch.folder("Inbox")
    let folder = try addTemporary(inbox, settings: deleting)
    try FileManager.default.removeItem(at: inbox)

    try engine.setTemporary(folder, false)
    #expect(try engine.store.folder(id: try #require(folder.id))?.wearsTemporary == false)
  }

  @Test func openingARunDropsRunsLeftEmpty() throws {
    let stale = try engine.store.beginRun(at: takenOff)
    let fresh = try engine.store.beginRun(at: later)
    #expect(stale != fresh)
    let runs = try engine.store.database.read {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM run")
    }
    #expect(runs == 1)
  }

  @Test func missingSinceKeepsTheFirstTimeAndClearsOnceFound() throws {
    let id = try #require(addTemporary(scratch.url).id)
    try engine.store.recordMissing(folderID: id, isMissing: true, at: takenOff)
    try engine.store.recordMissing(folderID: id, isMissing: true, at: later)
    #expect(try engine.store.folder(id: id)?.missingSince == takenOff)
    try engine.store.recordMissing(folderID: id, isMissing: false, at: later)
    #expect(try engine.store.folder(id: id)?.missingSince == nil)
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
    // Turning off writes only the database, so it works, and the tag still waits to be read.
    try engine.setTemporary(try #require(try engine.store.folder(id: id)), false)
    #expect(try engine.store.hasLegacyTag(folderID: id))
    #expect(try engine.store.folder(id: id)?.wearsTemporary == false)
  }
}
