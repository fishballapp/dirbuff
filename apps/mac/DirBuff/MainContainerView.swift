import AppKit
import DirBuffCore
import DirBuffKit
import DirBuffUI
import SwiftUI

/// DirBuff's main window content: binds the app model's state and actions to `MainView`. Each
/// pushed page is built in its own `MainContainerView+<Page>` file.
struct MainContainerView: View {
  var appModel: AppModel
  @Bindable var windowState: MainWindowState
  var coordinator: WindowCoordinator

  var body: some View {
    TimelineView(CountdownSchedule()) { timeline in
      mainView(now: timeline.date)
    }
    .sheet(item: signInSheet) { sheet in
      GoogleSignInSheet(
        state: sheet,
        onSignIn: appModel.signInWithGoogle,
        onDismiss: appModel.dismissSignIn,
        onConfirm: appModel.confirmSignIn,
        onUseAnotherAccount: appModel.useAnotherGoogleAccount,
        onStartNewBackup: appModel.startNewBackupHere)
    }
    .sheet(item: restoreFolderSheet) { sheet in
      RestoreFolderSheet(
        state: sheet,
        onCancel: appModel.closeRestoreFolder,
        onHide: appModel.hideRestoreFolder,
        onShowInFinder: appModel.showRestoredFolderInFinder,
        onFix: appModel.fixRestoreFolder)
    }
    .sheet(item: restoreFromDriveSheet) { sheet in
      RestoreFromDriveSheet(
        state: sheet,
        onSelectMac: appModel.pickBackedUpMac,
        onOpenMac: appModel.openBackup,
        onSubmitPassword: appModel.submitBackupPassword,
        onSelectFolder: appModel.selectBackedUpFolder,
        onSelectDate: appModel.selectBackedUpDate,
        onChoosePlace: appModel.chooseRestorePlace,
        onRestore: appModel.restoreFromDrive,
        onRestoreAnother: appModel.restoreAnotherFromDrive,
        onBack: appModel.backToRestored,
        onKeep: appModel.keepBackingUpHere,
        onShowInFinder: appModel.showRestoredFolderInFinder,
        onFix: appModel.fixRestoreFromDrive,
        onClose: appModel.closeRestoreFromDrive)
    }
  }

  /// The Restore Folder sheet while it's open. Closing it any other way is Cancel.
  private var restoreFolderSheet: Binding<RestoreFolderState?> {
    let appModel = appModel
    return Binding(
      get: { appModel.restoreFolderSheet },
      set: { if $0 == nil, appModel.restoreFolderSheet != nil { appModel.closeRestoreFolder() } })
  }

  private var restoreFromDriveSheet: Binding<RestoreFromDriveState?> {
    let appModel = appModel
    return Binding(
      get: { appModel.restoreFromDriveSheet },
      set: {
        if $0 == nil, appModel.restoreFromDriveSheet != nil { appModel.closeRestoreFromDrive() }
      })
  }

  /// The Google sign-in sheet while the app asks for it. Closing it any other way is Not Now.
  private var signInSheet: Binding<GoogleSignInState?> {
    let appModel = appModel
    return Binding(
      get: { appModel.signInSheet },
      set: { if $0 == nil, appModel.signInSheet != nil { appModel.dismissSignIn() } })
  }

  private func mainView(now: Date) -> some View {
    let state = appModel.shelfState(now: now)
    return MainView(
      state: state,
      navigation: $windowState.navigation,
      actions: actions,
      folderPage: { AnyView(folderPage($0, state: state, now: now)) },
      history: { AnyView(historyPage(folderID: nil, now: now)) },
      page: { page in
        switch page {
        case .files(let id): AnyView(filesPage(id, state: state, now: now))
        case .folderHistory(let id): AnyView(historyPage(folderID: id, now: now))
        case .run(let id): AnyView(runPage(id, now: now))
        case .unreadFiles(let id): AnyView(unreadFilesPage(id))
        case .backup(let id): AnyView(backupPage(id))
        }
      }
    )
  }

  /// Every shelf action, wired to the app; pages built in other files use it too.
  var actions: ShelfActions {
    let appModel = appModel
    var actions = ShelfActions()
    actions.addFolder = addFolder
    actions.chooseFolderForBuff = chooseFolderForBuff
    actions.addBuff = { id, buff in await appModel.addBuff(buff, on: id) }
    actions.undoAddBuff = { id, buff in Task { await appModel.undoAddBuff(buff, on: id) } }
    actions.takeOff = { id, buff in Task { await appModel.confirmTakeOff(buff, on: id) } }
    actions.fix = { id, fix in appModel.perform(fix, on: id) }
    actions.locate = { id in Task { await appModel.locate(folderID: id) } }
    actions.removeFolder = { id in Task { await appModel.removeFolderAsking(folderID: id) } }
    actions.showInFinder = { id in
      guard let folder = appModel.folder(id: id) else { return }
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
    }
    actions.openLicenceSettings = coordinator.openSettings
    actions.buy = appModel.openCheckout
    actions.enterKey = coordinator.openKeyEntry
    actions.checkLicence = { Task { await appModel.checkLicenceNow() } }
    return actions
  }

  /// Adds the folder the user chooses, wearing nothing, and opens its page; one already added
  /// just opens.
  private func addFolder() {
    guard let url = NSOpenPanel.chooseFolderToAdd() else { return }
    Task {
      guard let id = await appModel.addFolder(url)?.id else { return }
      windowState.navigation = MainNavigation(.folder(id))
    }
  }

  private func chooseFolderForBuff(_ buff: Buff) {
    let chosen: URL? =
      switch buff {
      case .temporary: NSOpenPanel.chooseFolderToMakeTemporary()
      case .backup: NSOpenPanel.chooseFolderToBackUp()
      case .organise, .search: nil
      }
    guard let url = chosen else { return }
    Task {
      await appModel.addBuff(buff, toFolderAt: url)
      guard let id = appModel.report(for: url)?.folder.id else { return }
      windowState.navigation = MainNavigation(.folder(id))
    }
  }
}
