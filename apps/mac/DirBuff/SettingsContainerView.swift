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
      onOpenSetup: coordinator.openWelcome,
      onLicenceAction: perform
    )
  }

  private func perform(_ action: LicenceSettings.Action) {
    switch action {
    case .buy, .renew: appModel.openCheckout()
    case .checkNow: Task { await appModel.checkLicenceNow() }
    case .enterKey: coordinator.openKeyEntry()
    case .deactivate: Task { await appModel.deactivate() }
    case .manageSubscription: appModel.openCustomerPortal()
    }
  }
}
