import Foundation
import Testing

@testable import DirBuffKit

/// The gate every restic command passes: one at a time, in order, and a job cancelled while it
/// waits leaves without running.
@Suite struct OneAtATimeTests {
  /// What ran, in order.
  private actor Log {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
  }

  private func waitUntil(_ gate: OneAtATime, has count: Int) async throws {
    let reached = try await wait { await gate.waitingCount == count }
    #expect(reached, "The gate never had \(count) waiting")
  }

  @Test func aJobCancelledWhileItWaitsLeavesAtOnceAndNeverRuns() async throws {
    let gate = OneAtATime()
    let hold = Hold()
    let log = Log()
    let holder = Task { try await gate.run { await hold.hold() } }
    await hold.waitUntilHeld()
    let waiter = Task { try await gate.run { await log.add("ran") } }
    try await waitUntil(gate, has: 1)

    waiter.cancel()

    // It leaves while the gate is still held, not when the holder lets go.
    await #expect(throws: CancellationError.self) { try await waiter.value }
    #expect(await gate.waitingCount == 0)
    await hold.letGo()
    try await holder.value
    #expect(await log.entries.isEmpty)
    // The gate is free again.
    try await gate.run { await log.add("next") }
    #expect(await log.entries == ["next"])
  }

  @Test func theRunningJobCancelledPassesTheGateOn() async throws {
    let gate = OneAtATime()
    let entered = Signal()
    let log = Log()
    let running = Task {
      try await gate.run {
        await entered.send()
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        throw CancellationError()
      }
    }
    await entered.wait()
    let next = Task { try await gate.run { await log.add("next") } }
    try await waitUntil(gate, has: 1)

    running.cancel()

    await #expect(throws: CancellationError.self) { try await running.value }
    try await next.value
    #expect(await log.entries == ["next"])
  }

  @Test func waitersGoInOrderAndOneCancelledInTheMiddleIsSkipped() async throws {
    let gate = OneAtATime()
    let hold = Hold()
    let log = Log()
    let holder = Task { try await gate.run { await hold.hold() } }
    await hold.waitUntilHeld()
    var waiters: [Task<Void, any Error>] = []
    for name in ["a", "b", "c", "d"] {
      waiters.append(Task { try await gate.run { await log.add(name) } })
      try await waitUntil(gate, has: waiters.count)
    }

    waiters[2].cancel()
    await #expect(throws: CancellationError.self) { try await waiters[2].value }
    await hold.letGo()

    try await holder.value
    for index in [0, 1, 3] { try await waiters[index].value }
    #expect(await log.entries == ["a", "b", "d"])
    #expect(await gate.waitingCount == 0)
  }

  @Test func aJobWhoseTaskIsAlreadyCancelledNeverRuns() async throws {
    let gate = OneAtATime()
    let log = Log()
    let job = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await gate.run { await log.add("ran") }
    }

    await #expect(throws: CancellationError.self) { try await job.value }
    #expect(await log.entries.isEmpty)
  }
}
