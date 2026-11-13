import Foundation
import Testing

/// How the tests wait: for the thing they are waiting on, never for a duration standing in for it.
/// A runner busy with other suites can make anything late, so a test asserts no elapsed time, and
/// the only clock here bounds a hang. Nor does it count what a retention policy kept after backups
/// made at the real time (`BackupFixture.stillToForget`): that depends on the hour it runs in.

/// How long a test waits for something that has to happen before it gives up: a bound on a hang,
/// never a measure of speed. Far above anything a busy runner takes, so it is never what decides.
let hangLimit = Duration.seconds(600)

/// Waits until `isDone` says so, looking every few milliseconds; false if `hangLimit` passed first.
func wait(until isDone: @Sendable () async throws -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now + hangLimit
  while ContinuousClock.now < deadline {
    if try await isDone() { return true }
    try await Task.sleep(for: .milliseconds(5))
  }
  return false
}

/// Waits until the file at `url` exists: how a test learns that a script it started got that far.
func waitForFile(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) async throws {
  let appeared = try await wait { exists(url) }
  #expect(appeared, "\(url.lastPathComponent) never appeared", sourceLocation: sourceLocation)
}

/// Something that happens once, for a test to wait on.
actor Signal {
  private var hasHappened = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func send() {
    hasHappened = true
    for waiter in waiting { waiter.resume() }
    waiting = []
  }

  func wait() async {
    guard !hasHappened else { return }
    await withCheckedContinuation { waiting.append($0) }
  }
}

/// Waits for a job another task runs to have started, and holds it there until it is let go.
actor Hold {
  private var entered = false
  private var isLetGo = false
  private var holding: CheckedContinuation<Void, Never>?
  private var waitingForEntry: CheckedContinuation<Void, Never>?

  /// The held job's body: says it is in, then waits to be let go.
  func hold() async {
    entered = true
    waitingForEntry?.resume()
    waitingForEntry = nil
    guard !isLetGo else { return }
    await withCheckedContinuation { holding = $0 }
  }

  /// Returns once a job is inside `hold()`.
  func waitUntilHeld() async {
    guard !entered else { return }
    await withCheckedContinuation { waitingForEntry = $0 }
  }

  func letGo() {
    isLetGo = true
    holding?.resume()
    holding = nil
  }
}
