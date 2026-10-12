import DirBuffUI
import SwiftUI

struct SetupContainerView: View {
  var appModel: AppModel

  var body: some View {
    SetupView(
      state: SetupState(
        isExtensionEnabled: !appModel.isFinderExtensionOff,
        isOpenAtLogin: appModel.isLoginItemEnabled,
        isOpenAtLoginRequiresApproval: appModel.loginItemNeedsApproval,
        isNotificationsEnabled: appModel.isNotificationAuthorized),
      onOpenExtensionManagement: appModel.openFinderExtensionsSettings,
      onToggleOpenAtLogin: appModel.setOpenAtLogin,
      onOpenLoginItemsSettings: appModel.openLoginItemsSettings,
      onRequestNotifications: appModel.requestNotificationPermission
    )
  }
}
