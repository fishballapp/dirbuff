import DirBuffKit
import DirBuffUI
import Foundation
import UserNotifications
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "notifications")

extension AppModel {
  /// After each hourly clean-up, with what its run removed. A run that couldn't be recorded
  /// journals nothing History can find, so it goes unannounced too.
  func didCleanUp(runID: Int64?, at hour: Date) async {
    let entries = await journal(runID: runID)
    await trimHistory()
    historyDidChange()
    if let notification = CleanUpNotification(entries: entries, reports: reports) {
      await notify(notification)
    }
    await notifyWhatsClearedTomorrow(now: hour)
  }

  /// Once a day per folder: "Downloads: 3 items will be moved to the Bin tomorrow".
  private func notifyWhatsClearedTomorrow(now: Date) async {
    let calendar = Calendar.current
    for report in reports {
      guard let id = report.folder.id, let wear = report.temporaryWear,
        let status = report.temporaryStatus
      else { continue }
      let count = status.upcoming.count {
        calendar.dateComponents(
          [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: $0.date)
        ).day == 1
      }
      guard count > 0 else { continue }
      let items = count == 1 ? "1 item" : "\(count) items"
      await notifyOncePerDay(
        id: "tomorrow.\(id)", now: now,
        title: URL(fileURLWithPath: report.folder.path).lastPathComponent,
        body: wear.settings.disposal == .delete
          ? "\(items) will be deleted permanently tomorrow."
          : "\(items) will be moved to the \(SystemBin.name) tomorrow.")
    }
  }

  private func journal(runID: Int64?) async -> [JournalEntry] {
    guard let runID else { return [] }
    let store = engine.store
    do {
      return try await Task.detached { try store.journal(runID: runID) }.value
    } catch {
      logger.error("Couldn't read the run: \(error.localizedDescription, privacy: .public)")
      return []
    }
  }

  func notifyOncePerDay(id: String, now: Date, title: String, body: String) async {
    let today = now.formatted(.iso8601.year().month().day())
    let lastNotifiedKey = "notified.\(id)"
    guard UserDefaults.standard.string(forKey: lastNotifiedKey) != today else { return }
    if await notify(id: id, title: title, body: body) {
      UserDefaults.standard.set(today, forKey: lastNotifiedKey)
    }
  }

  /// One notification for everything the clean-up moved, under one identifier, so the next
  /// clean-up's replaces it.
  @discardableResult
  func notify(_ notification: CleanUpNotification) async -> Bool {
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.categoryIdentifier = notification.category.rawValue
    content.threadIdentifier = CleanUpNotification.id
    content.userInfo = notification.userInfo
    content.interruptionLevel = .passive
    return await addNotification(id: CleanUpNotification.id, content: content)
  }

  /// A new notification with the same `id` replaces the last instead of stacking.
  @discardableResult
  func notify(id: String, title: String, body: String) async -> Bool {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.interruptionLevel = .passive
    return await addNotification(id: id, content: content)
  }

  private func addNotification(id: String, content: UNNotificationContent) async -> Bool {
    do {
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: id, content: content, trigger: nil))
      return true
    } catch {
      logger.error("Notification failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }
}

/// Posts a Backup notification to the system. Active, not passive: a backup's failure costs most
/// when nobody looks. Its identifier is the cause, so one cause's notification replaces its last.
struct SystemBackupNotifier: BackupNotifying {
  /// What the notification carries, so choosing it opens the folder.
  static let folderIDKey = "backupFolderID"

  func post(_ notification: BackupNotification) async -> Bool {
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.threadIdentifier = "backup"
    content.userInfo = [Self.folderIDKey: notification.folderID]
    do {
      try await UNUserNotificationCenter.current().add(
        UNNotificationRequest(identifier: notification.cause, content: content, trigger: nil))
      return true
    } catch {
      logger.error("Notification failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }
}
