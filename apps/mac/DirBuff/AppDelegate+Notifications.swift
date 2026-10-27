import AppKit
import DirBuffUI
import UserNotifications

extension AppDelegate: UNUserNotificationCenterDelegate {
  /// Makes the clean-up categories and sets the centre's delegate. Called before launch finishes,
  /// so an action that launches DirBuff reaches the delegate.
  func setUpNotifications() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self

    let putBack = UNNotificationAction(
      identifier: CleanUpNotification.Action.putBack.rawValue,
      title: CleanUpNotification.Action.putBack.title,
      options: []
    )
    let show = UNNotificationAction(
      identifier: CleanUpNotification.Action.show.rawValue,
      title: CleanUpNotification.Action.show.title,
      options: [.foreground]
    )
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: CleanUpNotification.Category.withPutBack.rawValue,
        actions: [putBack, show],
        intentIdentifiers: []
      ),
      UNNotificationCategory(
        identifier: CleanUpNotification.Category.showOnly.rawValue,
        actions: [show],
        intentIdentifiers: []
      ),
    ])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let actionIdentifier = response.actionIdentifier
    let userInfo = response.notification.request.content.userInfo
    let folderPath = CleanUpNotification.folderPath(from: userInfo)
    let putBackEntryIDs = CleanUpNotification.putBackEntryIDs(from: userInfo)

    await handleNotificationResponse(
      actionIdentifier: actionIdentifier,
      folderPath: folderPath,
      putBackEntryIDs: putBackEntryIDs
    )
  }

  private func handleNotificationResponse(
    actionIdentifier: String,
    folderPath: String?,
    putBackEntryIDs: [Int64]
  ) async {
    switch actionIdentifier {
    case CleanUpNotification.Action.putBack.rawValue:
      await appModel.putBack(entryIDs: putBackEntryIDs)
    case CleanUpNotification.Action.show.rawValue, UNNotificationDefaultActionIdentifier:
      guard let folderPath else { return }
      let url = URL(fileURLWithPath: folderPath)
      if appModel.report(for: url) == nil {
        await appModel.refresh()
      }
      windows.openMain(selecting: url)
    default:
      break
    }
  }
}
