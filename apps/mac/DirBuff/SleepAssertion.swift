import Foundation
import IOKit.pwr_mgt
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "backup")

/// `PreventUserIdleSystemSleep`, held while it lives: the Mac stays awake through a backup that
/// would outlast its idle timer. Closing the lid still sleeps it.
final class SleepAssertion {
  private var id = IOPMAssertionID(kIOPMNullAssertionID)

  /// Nil if macOS refused, when the backup goes on and the Mac may sleep under it.
  init?(reason: String) {
    let result = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
    guard result == kIOReturnSuccess else {
      logger.error("Couldn't keep the Mac awake: \(result)")
      return nil
    }
  }

  deinit { IOPMAssertionRelease(id) }
}
