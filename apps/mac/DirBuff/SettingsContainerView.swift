import DirBuffKit
import DirBuffUI
import SwiftUI

struct SettingsContainerView: View {
  var appModel: AppModel
  @ObservedObject var updates: Updates
  var coordinator: WindowCoordinator
  @AppStorage(AppModel.showInMenuBarKey) private var showInMenuBar = true
  @AppStorage(Updates.getsDevBuildsKey) private var getsDevBuilds = false

  var body: some View {
    SettingsView(
      state: SettingsState(
        openAtLogin: appModel.isLoginItemEnabled,
        openAtLoginRequiresApproval: appModel.loginItemNeedsApproval,
        showInMenuBar: showInMenuBar,
        shouldGetDevBuilds: getsDevBuilds,
        version: BuildInfo.version,
        canCheckForUpdates: updates.canCheck,
        licence: appModel.licence,
        licenceKey: appModel.licenceRecord.key),
      onToggleOpenAtLogin: appModel.setOpenAtLogin,
      onToggleShowInMenuBar: { showInMenuBar = $0 },
      onToggleGetDevBuilds: { isOn in
        getsDevBuilds = isOn
        if isOn { updates.checkInBackground() }
      },
      onCheckForUpdates: updates.check,
      onOpenLoginItemsSettings: appModel.openLoginItemsSettings,
      onOpenSetup: coordinator.openSetup,
      onBuy: appModel.openCheckout,
      onEnterKey: coordinator.openKeyEntry,
      onManageSubscription: appModel.openCustomerPortal,
      onDeactivate: { Task { await appModel.deactivate() } }
    )
  }
}
