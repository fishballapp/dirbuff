import DirBuffCore
import Foundation
import Testing

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
          now: now)
      ])

    let json = try #require(String(data: try file.encoded(), encoding: .utf8))

    #expect(json == Self.fixture.replacingOccurrences(of: "$HOME", with: fixtureHome))
    #expect(try BackupStatusFile.decoded(from: Data(json.utf8)) == file)
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
