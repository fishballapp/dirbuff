import Foundation
import Testing

@testable import DirBuffKit

/// A shell script plays restic, so a hang or a flood of identical status lines can be played out.
///
/// None of these asserts how long anything took: a runner busy with other suites can make a test
/// late, and a test that is late has proved nothing. Where a test says restic was stopped rather
/// than waited out, the stub says so itself: it waits for two minutes, and leaves a mark if it is
/// asked to stop (`SIGTERM`) before then.
@Suite(.serialized) struct ResticStallTests {
  private static let status =
    #"{"message_type":"status","percent_done":0.1,"total_files":10,"files_done":1,"total_bytes":1000,"bytes_done":100}"#

  /// A restic that prints `first`, leaves the mark `started`, and then waits for two minutes. Asked
  /// to stop, it leaves the mark `stopped` and ends; if it gets to the end of its wait it leaves
  /// `waitedOut`. (A runner so busy that restic is asked to stop before it has set up for it dies
  /// of that, leaving neither: it was stopped all the same.)
  private func waitingRestic(printing first: String, in scratch: Scratch) throws -> Restic {
    try stubRestic(
      """
      trap 'kill $(jobs -p); touch "\(scratch.url.path)/stopped"; exit 0' TERM
      echo '\(first)'
      sleep 120 &
      touch "\(scratch.url.path)/started"
      wait
      touch "\(scratch.url.path)/waitedOut"
      """, in: scratch)
  }

  private func hasBeenWaitedOut(_ scratch: Scratch) -> Bool {
    exists(scratch.url.appendingPathComponent("waitedOut"))
  }

  @Test func aBackupThatPrintsNothingMoreIsKilledForNoProgress() async throws {
    let scratch = try Scratch()
    let restic = try waitingRestic(printing: Self.status, in: scratch)
    let limit = StallLimit.noProgress(for: .milliseconds(500))

    await #expect(throws: ResticFailure.stalled(limit)) {
      try await restic.backup(scratch.url, stallLimit: limit)
    }

    #expect(!hasBeenWaitedOut(scratch), "restic was waited out and not stopped")
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
      for done in $(seq 1 60); do
        echo '{"message_type":"status","percent_done":0.1,"total_files":60,"files_done":'$done',"total_bytes":1000,"bytes_done":100}'
        sleep 0.1
      done
      echo '{"message_type":"summary","files_new":60,"files_changed":0,"files_unmodified":0,"dirs_new":1,"dirs_changed":0,"dirs_unmodified":0,"data_added":1,"data_added_packed":1,"total_files_processed":60,"total_bytes_processed":1000,"total_duration":1.5,"snapshot_id":"abc"}'
      """, in: scratch)
    let progress = ProgressLog()

    // It runs for six seconds, past the limit of five, with a status every tenth of a second: the
    // limit only trips if a runner holds this stub back for fifty times its pace.
    let result = try await restic.backup(
      scratch.url, stallLimit: .noProgress(for: .seconds(5)),
      onProgress: { progress.add($0) })

    #expect(result.summary.snapshotId == "abc")
    #expect(progress.all.count == 60)
    #expect(progress.all.map(\.filesDone) == Array(1...60))
  }

  @Test func aPruneThatRunsTooLongIsKilledOnTheClock() async throws {
    let scratch = try Scratch()
    let restic = try waitingRestic(printing: "loading all snapshots...", in: scratch)

    await #expect(throws: ResticFailure.stalled(.wallClock(.milliseconds(300)))) {
      try await restic.prune(wallClockLimit: .milliseconds(300))
    }

    #expect(!hasBeenWaitedOut(scratch), "restic was waited out and not stopped")
  }

  @Test func aCheckThatRunsTooLongIsKilledOnTheClock() async throws {
    let scratch = try Scratch()
    let restic = try waitingRestic(printing: "", in: scratch)

    await #expect(throws: ResticFailure.stalled(.wallClock(.milliseconds(300)))) {
      try await restic.check(wallClockLimit: .milliseconds(300))
    }

    #expect(!hasBeenWaitedOut(scratch), "restic was waited out and not stopped")
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
    let restic = try waitingRestic(printing: "", in: scratch)

    let task = Task { try await restic.prune(wallClockLimit: .seconds(120)) }
    // Cancelled once restic is running, however long a busy runner takes to start it.
    try await waitForFile(scratch.url.appendingPathComponent("started"))
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    // The call ends once restic has, which it does as soon as it is asked to.
    #expect(exists(scratch.url.appendingPathComponent("stopped")))
    #expect(!hasBeenWaitedOut(scratch))
  }

  /// A restic that ignores the request to stop and writes its process ID to `pid` once it does.
  /// It ends by itself when its scratch folder goes, so a test that fails leaves none running and
  /// none is ever signalled by a process ID that may already be free.
  private func stubbornRestic(in scratch: Scratch) throws -> Restic {
    try stubRestic(
      """
      trap '' TERM
      echo $$ > "\(scratch.url.path)/pid"
      while [ -d "\(scratch.url.path)" ]; do sleep 0.05; done
      """, in: scratch, terminationGrace: .milliseconds(200))
  }

  /// The stub's process ID, once it has written it.
  private func processID(in scratch: Scratch) async throws -> pid_t {
    let file = scratch.url.appendingPathComponent("pid")
    @Sendable func written() -> pid_t? {
      (try? String(contentsOf: file, encoding: .utf8)).flatMap {
        pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))
      }
    }
    // The shell makes the file before it writes the number in it.
    _ = try await wait { written() != nil }
    return try #require(written())
  }

  private func isRunning(_ processID: pid_t) -> Bool { kill(processID, 0) == 0 }

  @Test func aCancelledResticThatIgnoresTheRequestToStopIsKilled() async throws {
    let scratch = try Scratch()
    let restic = try stubbornRestic(in: scratch)

    let task = Task { try await restic.prune(wallClockLimit: .seconds(120)) }
    let processID = try await processID(in: scratch)
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!isRunning(processID), "The cancelled restic is still running")
    withExtendedLifetime(scratch) {}
  }

  @Test func theCommandAfterACancelledOneStartsOnceItsResticHasGone() async throws {
    let scratch = try Scratch()
    let restic = try stubbornRestic(in: scratch)
    let commands = OneAtATime()

    let cancelled = Task {
      try await commands.run { try await restic.prune(wallClockLimit: .seconds(120)) }
    }
    let processID = try await processID(in: scratch)
    cancelled.cancel()
    // Next in line, as Backup's commands are.
    let wasRunning = try await commands.run { isRunning(processID) }

    #expect(!wasRunning, "The next command started while the cancelled restic still ran")
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    withExtendedLifetime(scratch) {}
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
