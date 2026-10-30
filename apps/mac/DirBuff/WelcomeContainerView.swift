import AppKit
import DirBuffUI
import SwiftUI

/// The welcome window's content: the checklist from the app's live state, and the first buff put
/// on a folder from here.
struct WelcomeContainerView: View {
  var appModel: AppModel
  var coordinator: WindowCoordinator

  @State private var folders = WelcomeState.usualFolders()
  @State private var chosen: WelcomeFolder?
  @State private var otherFolder: WelcomeFolder?
  @State private var addedHere: Set<WelcomeFolder.ID> = []
  @State private var refusal: String?

  var body: some View {
    WelcomeView(
      state: WelcomeState(
        setup: SetupState(
          isExtensionEnabled: !appModel.isFinderExtensionOff,
          isOpenAtLogin: appModel.isLoginItemEnabled,
          isOpenAtLoginRequiresApproval: appModel.loginItemNeedsApproval,
          isNotificationsEnabled: appModel.isNotificationAuthorized),
        licence: appModel.licence, folders: folders, reports: appModel.reports,
        chosen: chosen, otherFolder: otherFolder, addedHere: addedHere, refusal: refusal),
      appIcon: Image(nsImage: NSApp.applicationIconImage),
      onChoose: { folder in Task { await choose(folder) } },
      onChooseOther: { Task { await chooseOtherFolder() } },
      onUndo: { placement in Task { await undo(placement) } },
      onChange: { coordinator.openMain(at: MainNavigation(.folder($0.folderID))) },
      onOpenExtensionManagement: appModel.openFinderExtensionsSettings,
      onToggleOpenAtLogin: appModel.setOpenAtLogin,
      onOpenLoginItemsSettings: appModel.openLoginItemsSettings,
      onRequestNotifications: appModel.requestNotificationPermission,
      onEnterKey: coordinator.openKeyEntry,
      onClose: coordinator.closeWelcome
    )
  }

  private func choose(_ folder: WelcomeFolder) async {
    refusal = nil
    if let reason = appModel.licence.refusal {
      refusal = reason
      return
    }
    chosen = folder
    if await appModel.addBuff(.temporary, toFolderAt: URL(fileURLWithPath: folder.path)) {
      addedHere.insert(folder.id)
    }
  }

  private func chooseOtherFolder() async {
    refusal = nil
    guard let url = NSOpenPanel.chooseFolderToMakeTemporary() else { return }
    // One of the usual folders, chosen this way, is still its own tile rather than a second one.
    let folder =
      folders.first { $0.path == url.path }
      ?? WelcomeFolder(name: url.lastPathComponent, path: url.path)
    if !folders.contains(folder) { otherFolder = folder }
    await choose(folder)
  }

  private func undo(_ placement: WelcomePlacement) async {
    await appModel.undoAddBuff(.temporary, on: placement.folderID)
    addedHere.remove(placement.folder.id)
  }
}
