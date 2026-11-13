import Foundation
import Testing

/// Swift Testing starts every test at once, and a test that waits on a restic hands its thread back,
/// so the real restic runs of some two hundred tests share the few cores of a CI runner. Each
/// takes minutes to finish, a restic started late hits the clocks it is held to, and what a test
/// measures is the queue it sat in. A suite marked `.runsRestic` runs at most `ResticSlots.count`
/// of its tests at a time instead, and the rest wait, costing nothing, for a free slot.
struct RunsRestic: SuiteTrait, TestTrait, TestScoping {
  var isRecursive: Bool { true }

  /// Only a test case takes a slot: a parameterized test's cases would otherwise wait for slots
  /// that their own test holds.
  func scopeProvider(for test: Test, testCase: Test.Case?) -> RunsRestic? {
    testCase == nil ? nil : self
  }

  func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    await ResticSlots.shared.take()
    let started = ContinuousClock.now
    do {
      try await function()
    } catch {
      await ResticSlots.shared.give()
      throw error
    }
    await ResticSlots.shared.give()
    if ProcessInfo.processInfo.environment["DIRBUFF_TEST_TIMINGS"] != nil {
      // What the test took once it had its turn, apart from the time it queued: to see how busy
      // the machine is, and to try a number of slots.
      print("timing: \(ContinuousClock.now - started) \(test.name)")
    }
  }
}

extension SuiteTrait where Self == RunsRestic {
  /// The suite runs the real restic: its tests take turns for the machine.
  static var runsRestic: RunsRestic { RunsRestic() }
}

/// The turns: first come, first served.
actor ResticSlots {
  static let shared = ResticSlots()

  /// Three per core, and never fewer than four: a restic spends much of its time waiting on the
  /// disk, so a turn per core left a 3-core runner at 330 s where nine turns took 110 s, with the
  /// same time per test once it had its turn (measured on a Mac held to about 3 cores by CPU
  /// burners: 3 turns 335 s, 6 157 s, 9 114 s, 15 105 s, 30 120 s, none 137 s; the time a test took
  /// once it had its turn, median 5 s for 3 to 15 turns, 7 s for 30, 16 to 23 s for none).
  /// `DIRBUFF_TEST_RESTIC_SLOTS` sets it, to try another.
  static let count: Int = {
    let set = ProcessInfo.processInfo.environment["DIRBUFF_TEST_RESTIC_SLOTS"].flatMap { Int($0) }
    return max(1, set ?? max(4, 3 * ProcessInfo.processInfo.activeProcessorCount))
  }()

  private var free = ResticSlots.count
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func take() async {
    if free > 0 {
      free -= 1
      return
    }
    await withCheckedContinuation { waiting.append($0) }
  }

  func give() {
    if waiting.isEmpty {
      free += 1
    } else {
      waiting.removeFirst().resume()
    }
  }
}
