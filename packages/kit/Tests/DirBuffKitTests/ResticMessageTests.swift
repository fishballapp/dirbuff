import Foundation
import Testing

@testable import DirBuffKit

/// The lines are what restic 0.19.1 printed.
@Suite struct ResticMessageTests {
  @Test func aBackupStatusIsProgress() {
    let line =
      #"{"message_type":"status","seconds_elapsed":3,"seconds_remaining":9,"percent_done":0.25,"total_files":8,"files_done":2,"total_bytes":4000,"bytes_done":1000,"current_files":["/a/b.txt"]}"#
    let message = ResticMessage(line: line, from: .backup)
    guard case .backupProgress(let progress) = message else {
      Issue.record("Read as \(message)")
      return
    }
    #expect(progress.percentDone == 0.25)
    #expect(progress.filesDone == 2)
    #expect(progress.totalBytes == 4000)
    #expect(progress.bytesDone == 1000)
    #expect(progress.currentFiles == ["/a/b.txt"])
  }

  @Test func whatIsZeroIsLeftOutAndReadAsZero() {
    let line = #"{"message_type":"status","percent_done":0}"#
    #expect(
      ResticMessage(line: line, from: .backup)
        == .backupProgress(
          BackupProgress(
            percentDone: 0, secondsElapsed: 0, totalFiles: 0, filesDone: 0, totalBytes: 0,
            bytesDone: 0, errorCount: 0, currentFiles: [])))
  }

  @Test func aRestoreStatusIsNotABackupStatus() {
    let line =
      #"{"message_type":"status","seconds_elapsed":1,"percent_done":0.5,"total_files":4,"files_restored":2,"total_bytes":10,"bytes_restored":5}"#
    guard case .restoreProgress(let progress) = ResticMessage(line: line, from: .restore) else {
      Issue.record("Not read as restore progress")
      return
    }
    #expect(progress.filesRestored == 2)
    #expect(progress.bytesRestored == 5)
    #expect(progress.filesSkipped == 0)
  }

  @Test func aBackupSummary() {
    let line =
      #"{"message_type":"summary","files_new":1,"files_changed":0,"files_unmodified":0,"dirs_new":7,"dirs_changed":0,"dirs_unmodified":0,"data_blobs":1,"tree_blobs":8,"data_added":3514,"data_added_packed":2918,"total_files_processed":1,"total_bytes_processed":3,"total_duration":0.99,"backup_start":"2026-11-10T13:20:41.447504Z","backup_end":"2026-11-10T13:20:42.44315Z","snapshot_id":"10e8597a97aa8fe9e5ae581cea77bd624ef0693687d95ba81b7bc4a140684c86"}"#
    guard case .backupSummary(let summary) = ResticMessage(line: line, from: .backup) else {
      Issue.record("Not read as a backup summary")
      return
    }
    #expect(summary.filesNew == 1)
    #expect(summary.dirsNew == 7)
    #expect(summary.dataAdded == 3514)
    #expect(summary.snapshotId?.hasPrefix("10e8597a") == true)
  }

  @Test func aFileThatCouldNotBeRead() {
    let line =
      #"{"message_type":"error","error":{"message":"open /x/secret: permission denied"},"during":"archival","item":"/x/secret"}"#
    #expect(
      ResticMessage(line: line, from: .backup)
        == .itemError(
          ItemError(
            item: "/x/secret", message: "open /x/secret: permission denied", during: "archival")))
  }

  @Test func theLastWordOfAFailedCommand() {
    let line =
      #"{"message_type":"exit_error","code":12,"message":"Fatal: wrong password or no key found"}"#
    #expect(
      ResticMessage(line: line, from: .other)
        == .exitError(code: 12, message: "Fatal: wrong password or no key found"))
  }

  @Test func aCheckSummaryWithNothingBroken() {
    let line =
      #"{"message_type":"summary","num_errors":0,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":false}"#
    guard case .checkSummary(let summary) = ResticMessage(line: line, from: .check) else {
      Issue.record("Not read as a check summary")
      return
    }
    #expect(summary.isHealthy)
    #expect(summary.brokenPacks.isEmpty)
  }

  @Test func aCheckSummaryWithABrokenPack() {
    let line =
      #"{"message_type":"summary","num_errors":1,"broken_packs":["abc"],"suggest_repair_index":true,"suggest_prune":false}"#
    guard case .checkSummary(let summary) = ResticMessage(line: line, from: .check) else {
      Issue.record("Not read as a check summary")
      return
    }
    #expect(!summary.isHealthy)
    #expect(summary.brokenPacks == ["abc"])
    #expect(summary.suggestRepairIndex)
  }

  @Test func theRepositoryAnInitCreated() {
    let line = #"{"message_type":"initialized","id":"eda95c5b","repository":"/tmp/r"}"#
    #expect(
      ResticMessage(line: line, from: .initialisation) == .initialized(repositoryID: "eda95c5b"))
  }

  @Test func whatIsNotAKnownMessageIsKeptAsText() {
    #expect(ResticMessage(line: "done", from: .backup) == .other("done"))
    let unknown = #"{"message_type":"brand_new","x":1}"#
    #expect(ResticMessage(line: unknown, from: .backup) == .other(unknown))
    #expect(ResticMessage(line: "[]", from: .other) == .other("[]"))
  }

  @Test(
    arguments: [
      (0, ResticExit.success), (1, .failed), (2, .goRuntimeError), (3, .incomplete),
      (10, .repositoryMissing), (11, .lockFailed), (12, .wrongPassword), (130, .cancelled),
      (42, .other(42)),
    ] as [(Int32, ResticExit)])
  func anExitCodeHasAName(code: Int32, exit: ResticExit) {
    #expect(ResticExit(code: code) == exit)
  }
}
