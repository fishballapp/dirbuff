import DirBuffCore
import Foundation
import Testing
import os

@testable import DirBuffKit

/// `backup-status.json` is read by programs outside DirBuff, so its encoding is pinned to a
/// fixture: a change that breaks this test changes the format, and needs a new `version`.
@Suite struct BackupStatusFileTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let documents = "\(fixtureHome)/Documents"

  private func attempt(
    _ minutesAgo: Double, snapshot: String? = nil, error: String? = nil, ended: Bool = true
  ) -> BackupAttempt {
    let start = now.addingTimeInterval(-minutesAgo * 60)
    return BackupAttempt(
      startedAt: start, endedAt: ended ? start.addingTimeInterval(90) : nil, snapshotID: snapshot,
      filesNew: snapshot == nil ? 0 : 12, filesChanged: snapshot == nil ? 0 : 3,
      bytesAdded: snapshot == nil ? 0 : 4_096, skippedCount: snapshot == nil ? 0 : 1, error: error)
  }

  private func status(
    lastSuccess: Double? = 30, failedRuns: Int = 0, failingFor: Double = 300, error: String? = nil,
    skipped: Int = 0
  ) -> BackupStatus {
    BackupStatus(
      lastRunAt: now.addingTimeInterval(-30 * 60),
      lastSuccessAt: lastSuccess.map { now.addingTimeInterval(-$0 * 60) },
      lastError: error,
      failingSince: failedRuns > 0 ? now.addingTimeInterval(-failingFor * 60) : nil,
      failedRunsInARow: failedRuns,
      skipped: (0..<skipped).map { SkippedFile(path: "f\($0)", reason: "locked") })
  }

  private func state(_ status: BackupStatus, _ attempts: [BackupAttempt] = [])
    -> BackupStatusFile
    .State
  {
    BackupStatusFile.Folder(path: documents, status: status, attempts: attempts, now: now).state
  }

  @Test func theEncodingIsThePublishedFormat() throws {
    let file = BackupStatusFile(
      writtenAt: now,
      check: .init(BackupCheck(checkedAt: now.addingTimeInterval(-86_400), problem: nil)),
      folders: [
        BackupStatusFile.Folder(
          path: documents, status: status(skipped: 1),
          attempts: [
            attempt(0, ended: false),
            attempt(60, snapshot: "a1b2c3d4"),
            attempt(120, error: "Signed out of Google Drive"),
          ],
          progress: .init(
            RunProgress(
              folderID: 1, itemsDone: 40, itemsTotal: 120, bytesDone: 2_000_000,
              bytesTotal: 9_000_000, current: "a.mov"),
            movedAt: now.addingTimeInterval(-30)),
          now: now)
      ])

    let json = try #require(String(data: try file.encoded(), encoding: .utf8))

    #expect(json == Self.fixture.replacingOccurrences(of: "$HOME", with: fixtureHome))
    #expect(try BackupStatusFile.decoded(from: Data(json.utf8)) == file)
  }

  @Test func anAccountProblemIsAKeyOfItsOwn() throws {
    let file = BackupStatusFile(
      writtenAt: now, check: nil,
      account: .init(problem: .driveFull, since: now.addingTimeInterval(-3_600)), folders: [])

    let json = try #require(String(data: try file.encoded(), encoding: .utf8))

    #expect(json.contains("\"account\" : {\n    \"problem\" : \"driveFull\",\n    \"since\" :"))
    #expect(try BackupStatusFile.decoded(from: Data(json.utf8)) == file)
  }

  @Test func theFileNamesTheAccountProblemToFixFirst() async throws {
    let fixture = try BackupFixture()
    #expect(try fixture.backup.statusFile(now: now).account == nil)
    try fixture.store.recordAccountProblem(.full, at: now.addingTimeInterval(-60))
    try fixture.store.recordAccountProblem(.backupInBin, at: now.addingTimeInterval(-120))

    let account = try #require(try fixture.backup.statusFile(now: now).account)

    #expect(account == .init(problem: .backupInBin, since: now.addingTimeInterval(-120)))
  }

  @Test func theStateIsTheFoldersOwnRecordRead() {
    #expect(state(status(failedRuns: 3, error: "boom")) == .failing)
    #expect(state(status(lastSuccess: nil)) == .neverBackedUp)
    #expect(state(status(lastSuccess: 4 * 24 * 60)) == .stale)
    #expect(state(status(skipped: 2)) == .filesUnread)
    // One failure doesn't make a backup failing yet; hours of them do.
    #expect(state(status(failedRuns: 1, failingFor: 20, error: "boom")) == .upToDate)
    #expect(state(status(failedRuns: 1, failingFor: 200, error: "boom")) == .failing)
    // Running comes first, whatever else is true.
    #expect(state(status(failedRuns: 3, error: "boom"), [attempt(1, ended: false)]) == .running)
  }

  @Test func onlyTheNewestAttemptsAreListed() {
    let attempts = (0..<15).map { attempt(Double($0 + 1), snapshot: "s\($0)") }
    let folder = BackupStatusFile.Folder(
      path: documents, status: status(), attempts: attempts, now: now)
    #expect(folder.attempts.count == BackupStatusFile.attemptLimit)
    #expect(folder.attempts.first?.snapshotID == "s0")
  }

  @Test func theFileIsReplacedWholeAndItsFolderMade() throws {
    let scratch = try Scratch()
    let url = scratch.url.appendingPathComponent("DirBuff/\(BackupStatusFile.fileName)")
    let first = BackupStatusFile(writtenAt: now, check: nil, folders: [])
    let second = BackupStatusFile(
      writtenAt: now.addingTimeInterval(60),
      check: .init(BackupCheck(checkedAt: now, problem: "3 files are missing")), folders: [])

    try first.write(to: url)
    try second.write(to: url)

    #expect(try BackupStatusFile.decoded(from: Data(contentsOf: url)) == second)
    let leftovers = try FileManager.default.contentsOfDirectory(
      atPath: url.deletingLastPathComponent().path)
    #expect(leftovers == [BackupStatusFile.fileName])
  }

  @Test func theFileTellsWhatABackupRunDid() async throws {
    let fixture = try BackupFixture()
    let id = try fixture.addWearing("docs")
    try fixture.scratch.file("docs/a.txt", bytes: 100)
    let runID = try fixture.store.beginBackupRun(folderID: id, at: now)
    #expect(try fixture.backup.statusFile(now: now).folders.first?.runningSince == now)

    try await fixture.run(id, at: now, runID: runID)
    try fixture.store.endRun(id: runID)

    // The snapshot was saved just now, by restic's clock.
    let file = try fixture.backup.statusFile(now: Date())
    let folder = try #require(file.folders.first)
    #expect(file.check == nil)
    #expect(
      folder.path == (try canonicalPath(of: fixture.scratch.url.appendingPathComponent("docs"))))
    #expect(folder.state == .upToDate && folder.runningSince == nil)
    #expect(folder.lastSuccessAt != nil && folder.lastError == nil)
    let attempt = try #require(folder.attempts.first)
    #expect(attempt.outcome == .saved && attempt.filesNew == 1 && attempt.snapshotID != nil)
  }

  // MARK: - A running backup

  /// A scratch status file, a clock the test moves, and a folder wearing Backup with a running
  /// attempt, as the app has one while restic works.
  private struct Running {
    let fixture: BackupFixture
    let url: URL
    let folderID: Int64
    let runID: Int64
    let clock: OSAllocatedUnfairLock<Date>
    let writer: BackupStatusWriter

    init(at start: Date) throws {
      fixture = try BackupFixture()
      url = fixture.scratch.url.appendingPathComponent("status/\(BackupStatusFile.fileName)")
      folderID = try fixture.addWearing("docs")
      runID = try fixture.store.beginBackupRun(folderID: folderID, at: start)
      let clock = OSAllocatedUnfairLock(initialState: start)
      self.clock = clock
      writer = BackupStatusWriter(
        backup: fixture.backup, url: url, now: { clock.withLock { $0 } })
    }

    var time: Date { clock.withLock { $0 } }

    func advance(_ seconds: TimeInterval) { clock.withLock { $0.addTimeInterval(seconds) } }

    func progress(bytes: Int64, files: Int = 10) -> RunProgress {
      RunProgress(
        folderID: folderID, itemsDone: files, itemsTotal: 100, bytesDone: bytes,
        bytesTotal: 1_000_000, current: "file-\(files)")
    }

    func file() throws -> BackupStatusFile {
      try BackupStatusFile.decoded(from: Data(contentsOf: url))
    }

    func folder() throws -> BackupStatusFile.Folder {
      try #require(try file().folders.first)
    }
  }

  @Test func aRunningBackupsFileMovesWithItsProgress() async throws {
    let run = try Running(at: now)
    try await run.writer.backupBegan(folderID: run.folderID)
    var folder = try run.folder()
    #expect(folder.state == .running && folder.runningSince == now)
    #expect(folder.progress == nil)

    // Restic reports every second, but the file is written about once a minute.
    run.advance(30)
    try await run.writer.report(run.progress(bytes: 100))
    #expect(try run.file().writtenAt == now)

    run.advance(30)
    try await run.writer.report(run.progress(bytes: 200, files: 12))
    folder = try run.folder()
    #expect(try run.file().writtenAt == now.addingTimeInterval(60))
    #expect(
      folder.progress
        == .init(
          run.progress(bytes: 200, files: 12), movedAt: now.addingTimeInterval(60)))
    #expect(folder.progress?.filesTotal == 100 && folder.progress?.bytesTotal == 1_000_000)

    run.advance(60)
    try await run.writer.report(run.progress(bytes: 900, files: 30))
    folder = try run.folder()
    #expect(try run.file().writtenAt == now.addingTimeInterval(120))
    #expect(folder.progress?.bytesDone == 900 && folder.progress?.filesDone == 30)
    #expect(folder.progress?.movedAt == now.addingTimeInterval(120))
  }

  @Test func nothingIsWrittenWhileNothingMoves() async throws {
    let run = try Running(at: now)
    try await run.writer.backupBegan(folderID: run.folderID)
    run.advance(60)
    try await run.writer.report(run.progress(bytes: 500))
    let moved = now.addingTimeInterval(60)
    #expect(try run.file().writtenAt == moved)

    // The same count again, for ten minutes: no write, so the file still says when it moved.
    for _ in 0..<10 {
      run.advance(60)
      try await run.writer.report(run.progress(bytes: 500))
    }
    #expect(try run.file().writtenAt == moved)

    // Another write of the file (a check, say) keeps the count, and when that last moved: a
    // reader sees `writtenAt` new and `movedAt` ten minutes old.
    try await run.writer.write()
    let file = try run.file()
    #expect(file.writtenAt == moved.addingTimeInterval(600))
    #expect(try run.folder().progress?.movedAt == moved)

    // And the moment it moves again, once the interval has passed, the file says so.
    run.advance(60)
    try await run.writer.report(run.progress(bytes: 501))
    #expect(try run.folder().progress?.movedAt == moved.addingTimeInterval(660))
  }

  @Test func movedAtMovesOnlyWhenTheBackupGotFurther() async throws {
    let run = try Running(at: now)
    try await run.writer.backupBegan(folderID: run.folderID)
    run.advance(60)
    try await run.writer.report(run.progress(bytes: 500))
    let moved = now.addingTimeInterval(60)
    #expect(try run.folder().progress?.movedAt == moved)

    // Restic keeps counting the folder and moves on to other files, but is no further on.
    run.advance(60)
    try await run.writer.report(
      RunProgress(
        folderID: run.folderID, itemsDone: 10, itemsTotal: 150, bytesDone: 500,
        bytesTotal: 3_000_000, current: "another-file"))

    // That is worth writing, as the totals changed, but not a move.
    var progress = try #require(try run.folder().progress)
    #expect(progress.filesTotal == 150 && progress.bytesTotal == 3_000_000)
    #expect(progress.movedAt == moved)
    #expect(try run.file().writtenAt == moved.addingTimeInterval(60))

    // A different file alone is not worth a write, nor a move.
    run.advance(60)
    try await run.writer.report(
      RunProgress(
        folderID: run.folderID, itemsDone: 10, itemsTotal: 150, bytesDone: 500,
        bytesTotal: 3_000_000, current: "yet-another"))
    #expect(try run.file().writtenAt == moved.addingTimeInterval(60))

    // Further on, it moves.
    run.advance(60)
    try await run.writer.report(run.progress(bytes: 501))
    progress = try #require(try run.folder().progress)
    #expect(progress.movedAt == moved.addingTimeInterval(180))
  }

  @Test func aWriteForAnotherReasonCarriesTheProgressAndSpacesTheNext() async throws {
    let run = try Running(at: now)
    try await run.writer.backupBegan(folderID: run.folderID)
    run.advance(50)
    try await run.writer.report(run.progress(bytes: 300))
    try await run.writer.write()
    #expect(try run.folder().progress?.bytesDone == 300)

    // The write at 50 s counts: the next progress write is a minute after it.
    run.advance(30)
    try await run.writer.report(run.progress(bytes: 400))
    #expect(try run.folder().progress?.bytesDone == 300)
    run.advance(30)
    try await run.writer.report(run.progress(bytes: 500))
    #expect(try run.folder().progress?.bytesDone == 500)
  }

  @Test func aTotalRestictHasntCountedYetIsLeftOut() async throws {
    let run = try Running(at: now)
    try await run.writer.backupBegan(folderID: run.folderID)
    run.advance(60)
    try await run.writer.report(
      RunProgress(
        folderID: run.folderID, itemsDone: 5, itemsTotal: 0, bytesDone: 50, bytesTotal: 0,
        current: nil))

    let progress = try #require(try run.folder().progress)
    #expect(progress.filesDone == 5 && progress.filesTotal == nil)
    #expect(progress.bytesDone == 50 && progress.bytesTotal == nil)
    let json = try #require(String(data: Data(contentsOf: run.url), encoding: .utf8))
    #expect(!json.contains("filesTotal") && !json.contains("bytesTotal"))
  }

  @Test func aBackupThatSavedIsWrittenAtOnceWithoutProgress() async throws {
    // The file keeps whole seconds.
    let run = try Running(at: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded()))
    try run.fixture.scratch.file("docs/a.txt", bytes: 100)
    try await run.writer.backupBegan(folderID: run.folderID)
    run.advance(60)
    try await run.writer.report(run.progress(bytes: 10))

    run.advance(5)
    try await run.fixture.run(run.folderID, at: Date(), runID: run.runID)
    try run.fixture.store.endRun(id: run.runID)
    try await run.writer.backupEnded(folderID: run.folderID)

    let folder = try run.folder()
    #expect(try run.file().writtenAt == run.time)
    #expect(folder.state != .running && folder.runningSince == nil && folder.progress == nil)
    #expect(folder.attempts.first?.outcome == .saved)

    // A report that lands after the end changes nothing.
    let ended = run.time
    run.advance(120)
    try await run.writer.report(run.progress(bytes: 20))
    #expect(try run.folder().progress == nil)
    #expect(try run.file().writtenAt == ended)
  }

  @Test func aFailedOrCancelledBackupIsWrittenAtOnce() async throws {
    let run = try Running(at: now)
    try await run.writer.backupBegan(folderID: run.folderID)
    run.advance(60)
    try await run.writer.report(run.progress(bytes: 10))
    #expect(try run.folder().progress != nil)

    // A cancelled backup is recorded as this one is: restic is killed and the run fails.
    run.advance(1)
    try run.fixture.store.recordBackupFailure(
      "cancelled", for: try run.fixture.record(run.folderID), runID: run.runID, at: Date())
    try run.fixture.store.endRun(id: run.runID)
    try await run.writer.backupEnded(folderID: run.folderID)

    let folder = try run.folder()
    #expect(try run.file().writtenAt == now.addingTimeInterval(61))
    #expect(folder.progress == nil && folder.runningSince == nil)
    #expect(folder.lastError == "cancelled" && folder.attempts.first?.outcome == .failed)
  }

  @Test func aBackupTheAccountHeldIsWrittenAtOnceWithTheCause() async throws {
    let run = try Running(at: now)
    try await run.writer.backupBegan(folderID: run.folderID)
    #expect(try run.folder().state == .running)

    // The account is found full before restic starts: nothing is recorded for the run, and the
    // run that did nothing goes when it ends.
    try run.fixture.store.recordAccountProblem(.full, at: now.addingTimeInterval(1))
    run.advance(2)
    try run.fixture.store.endRun(id: run.runID)
    try await run.writer.backupEnded(folderID: run.folderID)

    let file = try run.file()
    #expect(file.account == .init(problem: .driveFull, since: now.addingTimeInterval(1)))
    #expect(file.folders.first?.state != .running && file.folders.first?.progress == nil)
    #expect(file.writtenAt == now.addingTimeInterval(2))
  }

  @Test func aFileLeftRunningByAQuitIsCorrectedByTheNextLaunch() async throws {
    let run = try Running(at: now)
    try await run.writer.backupBegan(folderID: run.folderID)
    run.advance(60)
    try await run.writer.report(run.progress(bytes: 10))
    #expect(try run.folder().state == .running)

    // DirBuff is killed: the file says running for ever. The next launch closes the runs the quit
    // cut short, and its own writer, which has no backup running, writes the file.
    try run.fixture.store.closeInterruptedRuns(at: now.addingTimeInterval(3_600))
    let launched = BackupStatusWriter(
      backup: run.fixture.backup, url: run.url, now: { self.now.addingTimeInterval(3_700) })
    try await launched.write()

    let folder = try run.folder()
    #expect(folder.state != .running && folder.progress == nil && folder.runningSince == nil)
    #expect(folder.attempts.first?.error == BackupRunRecord.interruptedMessage)
    #expect(try run.file().writtenAt == now.addingTimeInterval(3_700))
  }

  /// The doc is private, so the public repo's copy of the tests has none to read.
  static let doc = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("docs/backup-status-file.md")

  @Test(.enabled(if: FileManager.default.fileExists(atPath: doc.path)))
  func theDocumentedExamplesDecode() throws {
    let text = try String(contentsOf: Self.doc, encoding: .utf8)
    let examples = text.components(separatedBy: "```json\n").dropFirst().compactMap {
      $0.components(separatedBy: "```").first
    }
    #expect(examples.count == 2)
    for example in examples {
      let file = try BackupStatusFile.decoded(from: Data(example.utf8))
      #expect(file.version == BackupStatusFile.currentVersion)
      // Written back, it says the same: the example has no key the real type doesn't know.
      let written = try JSONSerialization.jsonObject(with: file.encoded())
      let documented = try JSONSerialization.jsonObject(with: Data(example.utf8))
      #expect((written as? NSDictionary) == (documented as? NSDictionary))
    }
  }

  static let fixture = """
    {
      "check" : {
        "checkedAt" : "2027-01-14T08:00:00Z",
        "isWhole" : true
      },
      "folders" : [
        {
          "attempts" : [
            {
              "bytesAdded" : 0,
              "filesChanged" : 0,
              "filesNew" : 0,
              "outcome" : "running",
              "skippedCount" : 0,
              "startedAt" : "2027-01-15T08:00:00Z"
            },
            {
              "bytesAdded" : 4096,
              "endedAt" : "2027-01-15T07:01:30Z",
              "filesChanged" : 3,
              "filesNew" : 12,
              "outcome" : "saved",
              "skippedCount" : 1,
              "snapshotID" : "a1b2c3d4",
              "startedAt" : "2027-01-15T07:00:00Z"
            },
            {
              "bytesAdded" : 0,
              "endedAt" : "2027-01-15T06:01:30Z",
              "error" : "Signed out of Google Drive",
              "filesChanged" : 0,
              "filesNew" : 0,
              "outcome" : "failed",
              "skippedCount" : 0,
              "startedAt" : "2027-01-15T06:00:00Z"
            }
          ],
          "failedRunsInARow" : 0,
          "lastRunAt" : "2027-01-15T07:30:00Z",
          "lastSuccessAt" : "2027-01-15T07:30:00Z",
          "path" : "$HOME/Documents",
          "progress" : {
            "bytesDone" : 2000000,
            "bytesTotal" : 9000000,
            "filesDone" : 40,
            "filesTotal" : 120,
            "movedAt" : "2027-01-15T07:59:30Z"
          },
          "runningSince" : "2027-01-15T08:00:00Z",
          "state" : "running",
          "unreadFileCount" : 1
        }
      ],
      "version" : 1,
      "writtenAt" : "2027-01-15T08:00:00Z"
    }
    """
}
