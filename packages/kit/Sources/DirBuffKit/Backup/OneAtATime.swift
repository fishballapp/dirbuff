import Foundation

/// Runs one job at a time, in the order they came. Each restic command locks the repository, and
/// one waiting on another's lock fails, so the Mac runs one at a time.
///
/// A job whose task is cancelled while it waits leaves the queue at once, throwing
/// `CancellationError`, and never runs; one cancelled after its turn came is stopped before it
/// starts. The gate passes straight from one job to the next waiting, so none can slip in
/// between, and a waiter is either handed the gate or removed, never both.
actor OneAtATime {
  private var isBusy = false
  private var waiting: [Waiter] = []

  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Error>
  }

  func run<Result: Sendable>(_ job: @Sendable () async throws -> Result) async throws -> Result {
    try await acquire()
    defer { handOver() }
    try Task.checkCancellation()
    return try await job()
  }

  /// Takes the gate, or waits for it in turn.
  private func acquire() async throws {
    guard isBusy else {
      isBusy = true
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        enqueue(id, continuation)
      }
    } onCancel: {
      Task { await self.leave(id) }
    }
  }

  /// In the queue, unless its task was cancelled before it got there.
  private func enqueue(_ id: UUID, _ continuation: CheckedContinuation<Void, any Error>) {
    guard !Task.isCancelled else {
      continuation.resume(throwing: CancellationError())
      return
    }
    waiting.append(Waiter(id: id, continuation: continuation))
  }

  /// How many jobs wait for the gate, for tests.
  var waitingCount: Int { waiting.count }

  /// A cancelled waiter, if it is still waiting: out of the queue, told why.
  private func leave(_ id: UUID) {
    guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
    waiting.remove(at: index).continuation.resume(throwing: CancellationError())
  }

  /// To the next job waiting, which finds the gate still taken; or frees it.
  private func handOver() {
    guard !waiting.isEmpty else {
      isBusy = false
      return
    }
    waiting.removeFirst().continuation.resume()
  }
}
