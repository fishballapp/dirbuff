import DirBuffKit
import DirBuffUI
import SwiftUI

struct SettingsContainerView: View {
  var appModel: AppModel
  var coordinator: WindowCoordinator
  @AppStorage(AppModel.showInMenuBarKey) private var showInMenuBar = true

  var body: some View {
    SettingsView(
      state: SettingsState(
        openAtLogin: appModel.isLoginItemEnabled,
        openAtLoginRequiresApproval: appModel.loginItemNeedsApproval,
        showInMenuBar: showInMenuBar,
        licence: appModel.licence,
        licenceKey: appModel.licenceRecord.key),
      onToggleOpenAtLogin: appModel.setOpenAtLogin,
      onToggleShowInMenuBar: { showInMenuBar = $0 },
      onOpenLoginItemsSettings: appModel.openLoginItemsSettings,
      onOpenSetup: coordinator.openSetup,
      onBuy: appModel.openCheckout,
      onEnterKey: coordinator.openKeyEntry,
      onManageSubscription: appModel.openCustomerPortal,
      onDeactivate: { Task { await appModel.deactivate() } }
    )
  }
}
