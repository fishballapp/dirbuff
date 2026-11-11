import DirBuffCore
import Foundation
import GRDB
import Testing

@testable import DirBuffKit

/// A backup's History run: opened when the backup begins, kept through other runs' begins, and
/// closed by its end or by the next launch.
@Suite struct BackupRunHistoryTests {
  let store: Store
  let start = Date(timeIntervalSince1970: 1_800_000_000)

  init() throws {
    store = try Store.inMemory()
  }

  private func folderWearingBackup() throws -> Int64 {
    let id = try #require(
      store.insert(
        Folder(bookmark: Data([1]), path: "\(fixtureHome)/Documents", createdAt: start)
      ).id)
    try store.putOnBackup(folderID: id, settings: BackupSettings(), now: start)
    return id
  }

  private func saved(_ id: Int64, in runID: Int64, at date: Date) throws {
    try store.recordBackup(
      SavedBackup(
        snapshotID: "snap", savedAt: date, filesNew: 3, filesChanged: 2, bytesAdded: 500,
        skipped: [SkippedFile(path: "a", reason: "locked")], versions: [], cloudOnlyCount: 0),
      for: try require(store.backupRecord(folderID: id)), runID: runID, at: date)
  }

  @Test func aBackupRunIsRunningUntilItRecordsAnOutcome() throws {
    let id = try folderWearingBackup()
    let runID = try store.beginBackupRun(folderID: id, at: start)

    let running = try #require(try store.backupAttempts(folderID: id, limit: 5).first)
    #expect(running.outcome == .running && running.startedAt == start && running.endedAt == nil)

    let end = start.addingTimeInterval(60)
    try saved(id, in: runID, at: end)
    let done = try #require(try store.backupAttempts(folderID: id, limit: 5).first)
    #expect(done.outcome == .saved && done.endedAt == end && done.snapshotID == "snap")
    #expect(done.filesNew == 3 && done.filesChanged == 2 && done.bytesAdded == 500)
    #expect(done.skippedCount == 1)
  }

  @Test func aFailedBackupRunKeepsItsError() throws {
    let id = try folderWearingBackup()
    let runID = try store.beginBackupRun(folderID: id, at: start)

    try store.recordBackupFailure(
      "no route", for: try require(store.backupRecord(folderID: id)), runID: runID, at: start)

    let failed = try #require(try store.backupAttempts(folderID: id, limit: 5).first)
    #expect(failed.outcome == .failed && failed.error == "no route")
  }

  @Test func anOpenRunSurvivesOtherRunsBeginningAndEnding() throws {
    let id = try folderWearingBackup()
    let backupRun = try store.beginBackupRun(folderID: id, at: start)

    let cleanUp = try store.beginRun(of: .temporary, at: start)
    try store.endRun(id: cleanUp)
    _ = try store.beginRun(of: .temporary, at: start)

    try saved(id, in: backupRun, at: start)
    #expect(try store.backupRuns(runID: backupRun).map(\.snapshotID) == ["snap"])
  }

  @Test func clearingAndTrimmingKeepARunThatIsOpen() throws {
    let id = try folderWearingBackup()
    let open = try store.beginBackupRun(folderID: id, at: start)
    try store.endRun(id: try store.beginBackupRun(folderID: id, at: start.addingTimeInterval(-60)))

    try store.trimHistory(to: 0)
    try store.clearHistory()

    let remaining = try store.database.read { try Int64.fetchAll($0, sql: "SELECT id FROM run") }
    #expect(remaining == [open])
    #expect(try store.backupRuns(runID: open).count == 1)
  }

  @Test func endingARunDropsABackupThatNeverReachedAnOutcome() throws {
    let id = try folderWearingBackup()
    let runID = try store.beginBackupRun(folderID: id, at: start)

    try store.endRun(id: runID)

    #expect(try store.backupAttempts(folderID: id, limit: 5).isEmpty)
    #expect(try store.backupRuns(runID: runID).isEmpty)
  }

  @Test func aLaunchSettlesTheRunsAQuitCutShort() throws {
    let id = try folderWearingBackup()
    _ = try store.beginBackupRun(folderID: id, at: start)
    let cleanUp = try store.beginRun(of: .temporary, at: start)
    let relaunch = start.addingTimeInterval(600)

    try store.closeInterruptedRuns(at: relaunch)

    let attempt = try #require(try store.backupAttempts(folderID: id, limit: 5).first)
    #expect(attempt.outcome == .failed && attempt.endedAt == relaunch)
    #expect(attempt.error == BackupRunRecord.interruptedMessage)
    // The quit isn't a failure of the backup: nothing counts towards "Backups are failing".
    #expect(try store.backupRecord(folderID: id)?.failedRunsInARow == 0)
    // The clean-up's run did nothing, so it goes; nothing is open.
    let runs = try store.database.read { try Row.fetchAll($0, sql: "SELECT id, isOpen FROM run") }
    #expect(runs.count == 1 && runs.first?["isOpen"] == false)
    #expect(runs.first?["id"] != cleanUp)
    // And it stays settled: a later begin doesn't change it.
    _ = try store.beginRun(of: .temporary, at: relaunch)
    #expect(try store.backupAttempts(folderID: id, limit: 5).count == 1)
  }

  @Test func attemptsAreNewestFirstAndLimited() throws {
    let id = try folderWearingBackup()
    for minute in 0..<4 {
      let at = start.addingTimeInterval(Double(minute) * 3_600)
      let runID = try store.beginBackupRun(folderID: id, at: at)
      try store.recordBackupFailure(
        "try \(minute)", for: try require(store.backupRecord(folderID: id)), runID: runID, at: at)
    }

    #expect(
      try store.backupAttempts(folderID: id, limit: 3).map(\.error) == ["try 3", "try 2", "try 1"])
  }

  @Test func aNotificationIsRecordedForTheDayAndForgottenAfterwards() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let tomorrow = start.addingTimeInterval(86_400)
    #expect(try !store.wasNotified(cause: "full", on: start, calendar: calendar))

    try store.recordNotified(cause: "full", on: start, calendar: calendar)
    try store.recordNotified(cause: "other", on: start, calendar: calendar)

    #expect(
      try store.wasNotified(cause: "full", on: start.addingTimeInterval(600), calendar: calendar))
    #expect(try !store.wasNotified(cause: "full", on: tomorrow, calendar: calendar))
    try store.recordNotified(cause: "full", on: tomorrow, calendar: calendar)
    #expect(try store.wasNotified(cause: "full", on: tomorrow, calendar: calendar))
    // The other cause's day has passed, so its row is gone.
    let rows = try store.database.read {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM backupNotified")
    }
    #expect(rows == 1)
  }

  @Test func runsFromBeforeRunsWereOpenAreFinished() throws {
    let database = try DatabaseQueue()
    try Store.migrator.migrate(database, upTo: "backup on drive")
    try database.write {
      try $0.execute(
        sql: "INSERT INTO run (id, startedAt, buff) VALUES (1, ?, 'temporary')", arguments: [start])
    }

    try Store.migrator.migrate(database)

    let isOpen = try database.read { try Bool.fetchOne($0, sql: "SELECT isOpen FROM run") }
    #expect(isOpen == false)
  }
}
