import DirBuffKit
import Foundation

/// Where a Backup notification is posted: the system's, in the app. A protocol so that no test
/// posts a real one.
public protocol BackupNotifying: Sendable {
  /// Posts it; whether it went out.
  func post(_ notification: BackupNotification) async -> Bool
}

/// Entering needs-you posts one system notification, once per cause per day: the day's record is in the database, so a relaunch doesn't
/// repeat it. Asked again while a cause lasts, it posts again the next day.
public enum BackupAlerts {
  /// Posts what `folders` need and hasn't been posted today; returns what it posted. A
  /// notification that couldn't be posted (macOS refused) is tried again at the next call.
  @discardableResult
  public static func deliver(
    _ folders: [FolderState], store: Store, notifier: any BackupNotifying, now: Date,
    calendar: Calendar = .current
  ) async throws -> [BackupNotification] {
    var posted: [BackupNotification] = []
    for notification in BackupNotification.all(folders) {
      guard try !store.wasNotified(cause: notification.cause, on: now, calendar: calendar),
        await notifier.post(notification)
      else { continue }
      try store.recordNotified(cause: notification.cause, on: now, calendar: calendar)
      posted.append(notification)
    }
    return posted
  }
}
