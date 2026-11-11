import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// Temporary's wear, reading and runs that delete, on folders under the temporary directory. Runs
/// that bin are in SystemTests.
@Suite struct TemporaryBuffTests {
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

  /// An engine on a database as 0.1.x left it, with a folder for each URL.
  private func upgraded(_ folders: [URL]) throws -> TemporaryBuff {
    TemporaryBuff(
      engine: Engine(
        store: try legacyStore(
          try folders.map {
            LegacyFolder(bookmark: try $0.bookmarkData(), path: try canonicalPath(of: $0))
          })))
  }

  @Test func puttingTemporaryOnAndOffSetsTheDatabaseAndWritesNoTag() throws {
    let folderID = try #require(try engine.add(scratch.url).id)

    try temporary.putOn(folderID: folderID, now: later)
    let wear = try temporary.wear(folderID: folderID)
    #expect(
      wear
        == Wear(
          folderID: folderID, settings: TemporarySettings(), isPausedByLicence: false,
          lastRunAt: later))
    #expect(try finderTags(of: scratch.url).isEmpty)

    try temporary.takeOff(folderID: folderID)
    #expect(try temporary.wear(folderID: folderID) == nil)
    #expect(try finderTags(of: scratch.url).isEmpty)
  }

  @Test func aLicenceEndingPausesTemporaryUntilItIsPutBackOn() throws {
    let folderID = try temporary.addWearing(scratch.url, deleting)

    try temporary.setPausedByLicence(true, folderID: folderID)
    #expect(try temporary.requireWear(folderID).isPausedByLicence)
    #expect(try finderTags(of: scratch.url).isEmpty)

    try temporary.putOn(folderID: folderID)
    let wear = try temporary.requireWear(folderID)
    #expect(!wear.isPausedByLicence)
    #expect(wear.settings == deleting)
  }

  @Test func takingTemporaryOffForgetsItsSettings() throws {
    let folderID = try temporary.addWearing(scratch.url, deleting)
    try temporary.takeOff(folderID: folderID)
    try temporary.putOn(folderID: folderID, now: takenOff)

    #expect(try temporary.requireWear(folderID).settings == TemporarySettings())
  }

  @Test func aLicencePauseKeepsTheSettingsForPuttingBackOn() throws {
    let folderID = try temporary.addWearing(scratch.url, deleting)
    try temporary.setPausedByLicence(true, folderID: folderID)
    try temporary.putOn(folderID: folderID, now: takenOff)

    #expect(try temporary.requireWear(folderID).settings == deleting)
  }

  @Test func savingSettingsDoesntPutBackABuffTakenOffSinceTheCopy() throws {
    let folderID = try temporary.addWearing(scratch.url, deleting)
    try temporary.takeOff(folderID: folderID)

    try temporary.save(TemporarySettings(maxAgeDays: 7, disposal: .bin), folderID: folderID)

    #expect(try temporary.wear(folderID: folderID) == nil)
  }

  @Test func savingSettingsKeepsTheLicencePauseMadeSinceTheCopy() throws {
    let folderID = try temporary.addWearing(scratch.url, deleting)
    try temporary.setPausedByLicence(true, folderID: folderID)

    let changed = TemporarySettings(maxAgeDays: 7, disposal: .bin)
    try temporary.save(changed, folderID: folderID)

    let wear = try temporary.requireWear(folderID)
    #expect(wear.settings == changed)
    #expect(wear.isPausedByLicence)
  }

  @Test func choosingEmptyOnRestartCountsFromNow() throws {
    let folderID = try temporary.addWearing(scratch.url)
    let onRestart = TemporarySettings(rule: .emptyOnRestart)

    try temporary.save(onRestart, folderID: folderID, now: takenOff)
    #expect(try temporary.requireWear(folderID).lastRunAt == takenOff)

    try temporary.save(onRestart, folderID: folderID, now: later)
    #expect(try temporary.requireWear(folderID).lastRunAt == takenOff)
  }

  @Test func theLicencePausesAFolderItCantReach() throws {
    let folderID = try temporary.addWearing(scratch.url)
    try FileManager.default.removeItem(at: scratch.url)

    try temporary.setPausedByLicence(true, folderID: folderID)
    #expect(try temporary.requireWear(folderID).isPausedByLicence)
  }

  @Test func readingRemovesNothing() throws {
    let old = try scratch.file("old", bytes: 10_000)
    let folderID = try temporary.addWearing(scratch.url, deleting)
    let status = try temporary.read(folderID: folderID, now: later)
    #expect(status.wearsTemporary)
    #expect(status.dueNow.map(\.item.url.lastPathComponent) == ["old"])
    #expect(status.upcoming.map(\.item.url.lastPathComponent) == ["old"])
    #expect(status.size >= 10_000)
    #expect(exists(old))
  }

  @Test func runRemovesAndJournals() throws {
    let old = try scratch.file("old", bytes: 10_000)
    let id = try temporary.addWearing(scratch.url, deleting)

    let summary = try temporary.run(folderID: id, now: later)

    #expect(!exists(old))
    #expect(summary.failures == 0)
    let journal = try engine.store.journal(folderID: id)
    let entry = try #require(journal.first)
    #expect(journal.count == 1 && summary.items == 1 && summary.bytes == entry.size)
    #expect(entry.name == "old")
    #expect(entry.disposal == .delete && entry.binnedPath == nil && entry.reasons == [.age])
    #expect(try temporary.requireWear(id).lastRunAt == later)
  }

  @Test func runJournalsUnderItsRunAndReportsProgress() throws {
    try scratch.file("a", bytes: 100)
    try scratch.file("b", bytes: 300)
    let id = try temporary.addWearing(scratch.url, deleting)
    let runID = try engine.store.beginRun(of: .temporary, at: later)

    let (_, reports) = try temporary.runHearingProgress(folderID: id, now: later, runID: runID)

    #expect(try engine.store.journal(folderID: id).allSatisfy { $0.runID == runID })
    #expect(reports.map(\.itemsDone) == [0, 1, 2])
    #expect(reports.map(\.itemsTotal) == [2, 2, 2])
    // Sizes are what the files take on disk, so whole blocks.
    let last = try #require(reports.last)
    #expect(last.bytesDone == last.bytesTotal && last.bytesTotal >= 400)
    #expect(reports.dropLast().allSatisfy { $0.current != nil } && reports.last?.current == nil)
  }

  @Test func aRunThatRemovedNothingIsDropped() throws {
    try scratch.file("old")
    let id = try temporary.addWearing(scratch.url, deleting)
    let empty = try engine.store.beginRun(of: .temporary, at: later)
    try engine.store.endRun(id: empty)
    let full = try engine.store.beginRun(of: .temporary, at: later)
    try temporary.run(folderID: id, now: later, runID: full)
    try engine.store.endRun(id: full)

    #expect(try engine.store.journal(folderID: id).first?.runID == full)
  }

  @Test func takingOffAMissingFolderWorks() throws {
    let inbox = try scratch.folder("Inbox")
    let folderID = try temporary.addWearing(inbox, deleting)
    try FileManager.default.removeItem(at: inbox)

    try temporary.takeOff(folderID: folderID)
    #expect(try temporary.wear(folderID: folderID) == nil)
  }

  @Test func runDoesNothingWhileTheLicencePausesIt() throws {
    let old = try scratch.file("old")
    let folderID = try temporary.addWearing(scratch.url, deleting)
    try temporary.setPausedByLicence(true, folderID: folderID)

    #expect(try temporary.run(folderID: folderID, now: later).items == 0)
    #expect(exists(old))
  }

  @Test func cannotUndoADeletion() throws {
    try scratch.file("old")
    let id = try temporary.addWearing(scratch.url, deleting)
    try temporary.run(folderID: id, now: later)
    let entryID = try #require(engine.store.journal(folderID: id).first?.id)
    #expect(throws: TemporaryBuff.Failure.deletedPermanently) {
      try temporary.undo(journalEntryID: entryID)
    }
  }

  @Test func aFolderTheLicencePausedIsStillRead() throws {
    _ = try scratch.file("old", bytes: 10_000)
    let folderID = try temporary.addWearing(scratch.url, deleting)
    try temporary.setPausedByLicence(true, folderID: folderID)
    let status = try temporary.read(folderID: folderID, now: later)
    #expect(status.size >= 10_000)
    #expect(status.dueNow.isEmpty)
  }

  @Test func aFolderLeftWearingNothingStaysUntilRemoved() throws {
    let takenOffByHand = try temporary.addWearing(scratch.url, deleting)
    try temporary.takeOff(folderID: takenOffByHand)
    let endedByLicence = try temporary.addWearing(try scratch.folder("Exports"))
    try temporary.setPausedByLicence(true, folderID: endedByLicence)
    try temporary.takeOff(folderID: endedByLicence)

    #expect(try engine.store.folders().map(\.id) == [takenOffByHand, endedByLicence])
    #expect(try temporary.wearers().isEmpty)
  }

  @Test func listsItsWearersInTheOrderTheFoldersWereAdded() throws {
    let first = try temporary.addWearing(try scratch.folder("B"))
    let second = try temporary.addWearing(try scratch.folder("A"))
    try temporary.setPausedByLicence(true, folderID: second)
    #expect(try temporary.wearers().map(\.folderID) == [first, second])
  }

  @Test func refusesAProtectedFolderButTheFolderCanBeAdded() throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let folderID = try #require(try engine.add(home).id)
    #expect(temporary.refusal(for: home) == .protectedFolder)
    #expect(throws: Refusal.protectedFolder) { try temporary.putOn(folderID: folderID) }
    #expect(try temporary.wear(folderID: folderID) == nil)
  }

  @Test func aFolderFromBeforeThatWasTaggedWearsTemporaryAndLosesItsTag() throws {
    let folder = try scratch.folder("Inbox")
    try setFinderTags([LegacyTemporaryTag.name, "Red"], on: folder)
    let temporary = try upgraded([folder])
    let store = temporary.engine.store
    let id = try #require(store.folders().first?.id)

    _ = try temporary.engine.locate(folderID: id)
    let wear = try temporary.requireWear(id)
    #expect(!wear.isPausedByLicence && wear.settings == TemporarySettings(maxAgeDays: 90))
    #expect(try temporary.read(folderID: id).wearsTemporary)
    #expect(try finderTags(of: folder) == ["Red"])
    #expect(try !store.hasLegacyTag(folderID: id))
  }

  @Test func anUntaggedFolderFromBeforeIsNotTemporary() throws {
    let folder = try scratch.folder("Downloads")
    let temporary = try upgraded([folder])
    let store = temporary.engine.store
    let id = try #require(store.folders().first?.id)

    _ = try temporary.engine.locate(folderID: id)
    #expect(try temporary.wear(folderID: id) == nil)
    #expect(try !store.hasLegacyTag(folderID: id))
  }

  @Test func aFolderDIrBuffCantReachStaysPendingAndNothingActsOnIt() throws {
    let folder = try scratch.folder("Drive")
    try setFinderTags([LegacyTemporaryTag.name], on: folder)
    let temporary = try upgraded([folder])
    let store = temporary.engine.store
    let id = try #require(store.folders().first?.id)
    try FileManager.default.removeItem(at: folder)

    #expect(throws: (any Error).self) { try temporary.engine.locate(folderID: id) }
    // Taking off writes only the database, so it works, and the tag still waits to be read.
    try temporary.takeOff(folderID: id)
    #expect(try store.hasLegacyTag(folderID: id))
    #expect(try temporary.wear(folderID: id) == nil)
  }
}
