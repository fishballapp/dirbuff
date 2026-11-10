/// Runs one job at a time, in the order they came. Each restic command locks the repository, and
/// one waiting on another's lock fails, so the Mac runs one at a time.
actor OneAtATime {
  private var isBusy = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func run<Result: Sendable>(_ job: @Sendable () async throws -> Result) async throws -> Result {
    if isBusy {
      await withCheckedContinuation { waiting.append($0) }
    } else {
      isBusy = true
    }
    defer { handOver() }
    return try await job()
  }

  /// To the next job waiting, which finds the gate still taken; or frees it.
  private func handOver() {
    guard !waiting.isEmpty else {
      isBusy = false
      return
    }
    waiting.removeFirst().resume()
  }
}
