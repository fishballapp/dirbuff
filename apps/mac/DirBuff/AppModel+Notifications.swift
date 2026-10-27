import DirBuffKit
import DirBuffUI
import Foundation
import UserNotifications
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "notifications")

extension AppModel {
  /// After each hourly clean-up, with what each folder's run removed.
  func didCleanUp(_ runs: [Engine.RunResult], at hour: Date) async {
    await notifyWhatGoesTomorrow(now: hour)
  }

  /// Once a day per folder: "Downloads: 3 items go to the Bin tomorrow".
  private func notifyWhatGoesTomorrow(now: Date) async {
    let calendar = Calendar.current
    for report in reports {
      guard let id = report.folder.id, let status = report.status else { continue }
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
        body: report.folder.settings.disposal == .delete
          ? "\(items) will be deleted permanently tomorrow."
          : "\(items) will go to the \(SystemBin.name) tomorrow.")
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

  /// A new notification with the same `id` replaces the last instead of stacking.
  @discardableResult
  func notify(id: String, title: String, body: String) async -> Bool {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.interruptionLevel = .passive
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
