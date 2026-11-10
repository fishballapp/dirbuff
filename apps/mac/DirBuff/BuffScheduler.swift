import AppKit
import DirBuffCore

/// Times the buffs' runs, with a driver for each kind of `BuffSchedule`. The on-the-hour driver
/// calls `run` with its schedule and when the run was due, and never while its last run is still
/// going. The after-a-change driver (`AfterChangeDriver`) does its work through its own
/// `AfterChangeWork`, one backup at a time, whatever the clean-ups are doing.
@MainActor
final class BuffScheduler {
  private let onTheHour: OnTheHourDriver
  let afterChange: AfterChangeDriver

  init(
    afterChange: AfterChangeDriver, run: @escaping @MainActor (BuffSchedule, Date) async -> Void
  ) {
    onTheHour = OnTheHourDriver { await run(.onTheHour, $0) }
    self.afterChange = afterChange
  }

  func start() {
    onTheHour.start()
    afterChange.start()
  }
}

/// Runs on the hour, by the clock, and at no other time (`nextCleanUp`), so a forecast can say
/// when. An hour the Mac sleeps through is skipped, never made up on waking.
@MainActor
private final class OnTheHourDriver {
  private let run: @MainActor (Date) async -> Void
  private var timer: Timer?
  private var isRunning = false

  init(run: @escaping @MainActor (Date) async -> Void) {
    self.run = run
  }

  /// The driver lives as long as the app, so the observers below hold it strongly.
  func start() {
    schedule(after: Date())
    let workspace = NSWorkspace.shared.notificationCenter
    // A timer that falls due while the Mac sleeps fires the moment it wakes, so it's dropped
    // before sleep, synchronously.
    workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
      _ in MainActor.assumeIsolated { self.timer?.invalidate() }
    }
    workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
      _ in Task { @MainActor in self.schedule(after: Date()) }
    }
    for change in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
      NotificationCenter.default.addObserver(forName: change, object: nil, queue: .main) { _ in
        Task { @MainActor in self.schedule(after: Date()) }
      }
    }
  }

  private func schedule(after date: Date) {
    timer?.invalidate()
    let hour = nextCleanUp(after: date)
    let timer = Timer(fire: hour, interval: 0, repeats: false) { _ in
      Task { @MainActor in
        // From the later of the two: a timer the system held back past the next hour mustn't
        // schedule one already gone.
        self.schedule(after: max(hour, Date()))
        await self.fire(at: hour)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func fire(at hour: Date) async {
    guard !isRunning else { return }
    isRunning = true
    defer { isRunning = false }
    await run(hour)
  }
}
