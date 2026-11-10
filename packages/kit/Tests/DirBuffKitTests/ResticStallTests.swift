import Foundation
import Testing

@testable import DirBuffKit

/// A shell script plays restic, so a hang or a flood of identical status lines can be played out.
@Suite(.serialized) struct ResticStallTests {
  private static let status =
    #"{"message_type":"status","percent_done":0.1,"total_files":10,"files_done":1,"total_bytes":1000,"bytes_done":100}"#

  @Test func aBackupThatPrintsNothingMoreIsKilledForNoProgress() async throws {
    let scratch = try Scratch()
    let restic = try stubRestic("echo '\(Self.status)'\nexec sleep 60", in: scratch)
    let limit = StallLimit.noProgress(for: .milliseconds(500))
    let started = ContinuousClock.now

    await #expect(throws: ResticFailure.stalled(limit)) {
      try await restic.backup([scratch.url], stallLimit: limit)
    }

    #expect(ContinuousClock.now - started < .seconds(10))
  }

  @Test func aStatusThatRepeatsWhileNothingMovesIsNotProgress() async throws {
    // restic prints a status every second, hung or not.
    let scratch = try Scratch()
    let restic = try stubRestic(
      "while true; do echo '\(Self.status)'; sleep 0.05; done", in: scratch)
    let limit = StallLimit.noProgress(for: .milliseconds(500))

    await #expect(throws: ResticFailure.stalled(limit)) {
      try await restic.restore(snapshot: "latest", to: scratch.url, stallLimit: limit)
    }
  }

  @Test func aBackupThatKeepsMovingIsLeftAlonePastTheLimit() async throws {
    let scratch = try Scratch()
    let restic = try stubRestic(
      """
      for done in $(seq 1 40); do
        echo '{"message_type":"status","percent_done":0.1,"total_files":40,"files_done":'$done',"total_bytes":1000,"bytes_done":100}'
        sleep 0.1
      done
      echo '{"message_type":"summary","files_new":40,"files_changed":0,"files_unmodified":0,"dirs_new":1,"dirs_changed":0,"dirs_unmodified":0,"data_added":1,"data_added_packed":1,"total_files_processed":40,"total_bytes_processed":1000,"total_duration":1.5,"snapshot_id":"abc"}'
      """, in: scratch)
    let progress = ProgressLog()

    let result = try await restic.backup(
      [scratch.url], stallLimit: .noProgress(for: .seconds(3)),
      onProgress: { progress.add($0) })

    #expect(result.summary.snapshotId == "abc")
    #expect(progress.all.count == 40)
    #expect(progress.all.map(\.filesDone) == Array(1...40))
  }

  @Test func aPruneThatRunsTooLongIsKilledOnTheClock() async throws {
    let scratch = try Scratch()
    let restic = try stubRestic("echo 'loading all snapshots...'\nexec sleep 60", in: scratch)

    await #expect(throws: ResticFailure.stalled(.wallClock(.milliseconds(300)))) {
      try await restic.prune(wallClockLimit: .milliseconds(300))
    }
  }

  @Test func aCheckThatRunsTooLongIsKilledOnTheClock() async throws {
    let scratch = try Scratch()
    let restic = try stubRestic("exec sleep 60", in: scratch)

    await #expect(throws: ResticFailure.stalled(.wallClock(.milliseconds(300)))) {
      try await restic.check(wallClockLimit: .milliseconds(300))
    }
  }

  @Test func aResticThatIgnoresTheRequestToStopIsKilled() async throws {
    let scratch = try Scratch()
    let restic = try stubRestic(
      "trap '' TERM\nwhile true; do sleep 0.05; done", in: scratch,
      terminationGrace: .milliseconds(200))

    await #expect(throws: ResticFailure.stalled(.wallClock(.milliseconds(300)))) {
      try await restic.prune(wallClockLimit: .milliseconds(300))
    }
  }

  @Test func aCancelledTaskStopsRestic() async throws {
    let scratch = try Scratch()
    let restic = try stubRestic("exec sleep 60", in: scratch)
    let started = ContinuousClock.now

    let task = Task { try await restic.prune(wallClockLimit: .seconds(60)) }
    try await Task.sleep(for: .milliseconds(300))
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ContinuousClock.now - started < .seconds(10))
  }

  @Test(
    arguments: [
      (1, ResticExit.failed), (3, .incomplete), (10, .repositoryMissing), (11, .lockFailed),
      (12, .wrongPassword), (42, .other(42)),
    ] as [(Int32, ResticExit)])
  func theExitCodeAndLastWordAreReported(code: Int32, exit: ResticExit) async throws {
    let scratch = try Scratch()
    let restic = try stubRestic(
      #"echo '{"message_type":"exit_error","code":\#(code),"message":"boom"}' >&2; exit \#(code)"#,
      in: scratch)

    await #expect(throws: ResticFailure.exited(exit, message: "boom")) {
      try await restic.snapshots()
    }
  }

  @Test func aRestoreSignalledByAnotherProcessIsReportedAsFailed() async throws {
    let scratch = try Scratch()
    let restic = try stubRestic("kill -9 $$", in: scratch)

    await #expect {
      try await restic.snapshots()
    } throws: { error in
      guard case ResticFailure.exited(.other(-9), _) = error else { return false }
      return true
    }
  }

  @Test func aResticThatIsNotThereIsUnusable() async throws {
    let restic = Restic(
      executable: URL(fileURLWithPath: "/nonexistent/restic"), repository: "r", password: "p")

    await #expect {
      try await restic.snapshots()
    } throws: { error in
      guard case ResticFailure.unusable = error else { return false }
      return true
    }
  }
}

private final class ProgressLog: @unchecked Sendable {
  private let lock = NSLock()
  private var progress: [BackupProgress] = []

  var all: [BackupProgress] { lock.withLock { progress } }

  func add(_ item: BackupProgress) { lock.withLock { progress.append(item) } }
}
