import DirBuffKit
import DirBuffUI
import SwiftUI

struct SettingsContainerView: View {
  var appModel: AppModel
  @ObservedObject var updates: Updates
  var coordinator: WindowCoordinator
  @AppStorage(AppModel.showInMenuBarKey) private var showInMenuBar = true
  @AppStorage(Updates.getsDevBuildsKey) private var getsDevBuilds = false
  /// Protect with a Password… or Change Password…, while it's open.
  @State private var passwordSheet: BackupPasswordSheetState?

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
        licenceKey: appModel.licenceRecord.key,
        backup: BackupAccountSettings(
          isSignedIn: appModel.isSignedInToGoogle, account: appModel.googleAccount,
          isPasswordProtected: appModel.isBackupPasswordProtected)),
      onToggleOpenAtLogin: appModel.setOpenAtLogin,
      onToggleShowInMenuBar: { showInMenuBar = $0 },
      onToggleGetDevBuilds: { isOn in
        getsDevBuilds = isOn
        if isOn { updates.checkInBackground() }
      },
      onCheckForUpdates: updates.check,
      onOpenLoginItemsSettings: appModel.openLoginItemsSettings,
      onOpenSetup: coordinator.openWelcome,
      onLicenceAction: perform,
      onBackupAction: perform
    )
    .sheet(item: $passwordSheet) { sheet in
      BackupPasswordSheet(
        state: sheet,
        onSave: save,
        onCancel: { passwordSheet = nil })
    }
  }

  private func perform(_ action: BackupAccountSettings.Action) {
    switch action {
    case .signIn:
      coordinator.openMain(at: nil)
      appModel.askToSignIn(.settings)
    case .signOut: Task { await appModel.signOutOfGoogle() }
    case .setPassword: passwordSheet = BackupPasswordSheetState(mode: .set)
    case .changePassword: passwordSheet = BackupPasswordSheetState(mode: .change)
    case .removePassword: Task { await appModel.removeBackupPassword() }
    case .restoreFromDrive:
      coordinator.openMain(at: nil)
      appModel.askToRestoreFromDrive()
    }
  }

  /// Changes the backup's key, keeping the sheet open with why if it couldn't.
  /// One change at a time: a second click while one runs does nothing.
  private func save(_ password: String) {
    guard var sheet = passwordSheet, !sheet.isSaving else { return }
    sheet.isSaving = true
    sheet.failure = nil
    passwordSheet = sheet
    Task {
      let failure = await appModel.setBackupPassword(password)
      guard let sheet = passwordSheet else { return }
      if let failure {
        passwordSheet = sheet.afterFailure(
          failure, isNewPasswordKept: appModel.keychainHoldsBackupPassword(password))
      } else {
        passwordSheet = nil
      }
    }
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
