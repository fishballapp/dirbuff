import AppKit
import DirBuffKit
import DirBuffUI
import Foundation
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "restore")

/// Restore from Google Drive…: the Macs' backups, a backup's folders and dates, a place for the
/// folder, and Keep Backing Up Here. The sheet is the main window's, opened from Settings ›
/// Backup; signed out, the sign-in sheet comes first and leads here. Each step runs as the
/// restore now running (`startRestore`), and one that was cancelled or replaced touches nothing.
extension AppModel {
  /// Opens the sheet, or the sign-in sheet that leads to it.
  func askToRestoreFromDrive() {
    guard restoreFolderSheet == nil, restoreFromDriveSheet == nil, restoreRun == nil else { return }
    guard isSignedInToGoogle else {
      askToSignIn(.restore)
      return
    }
    openRestoreFromDrive()
  }

  /// The sign-in sheet's end, for the sign-in that was asked for to restore.
  func openRestoreFromDrive() {
    restoreContext = RestoreContext()
    restoreFromDriveSheet = RestoreFromDriveState(account: googleAccount)
    loadMacs()
  }

  private func loadMacs() {
    setDrive(.loadingMacs)
    let backup = backup
    startRestore { [self] run in
      do {
        let macs = try await backup.backedUpMacs()
        guard isCurrent(run) else { return }
        setDrive(.macs(macs))
      } catch {
        guard isCurrent(run) else { return }
        await failDrive(error, retry: { self.loadMacs() })
      }
    }
  }

  /// A Mac chosen in the list.
  func pickBackedUpMac(_ id: String) {
    restoreFromDriveSheet?.pickedMacID = id
  }

  /// Open Backup, for the Mac chosen.
  func openBackup(of mac: BackedUpMac) {
    restoreContext.mac = mac
    restoreFromDriveSheet?.mac = mac
    restoreContext.password = nil
    loadFolders(of: mac, password: nil)
  }

  /// Open Backup with the password typed.
  func submitBackupPassword(_ password: String) {
    guard let mac = restoreContext.mac else { return }
    setDrive(.password(PasswordAsk(macName: mac.name, isChecking: true)))
    loadFolders(of: mac, password: password)
  }

  private func loadFolders(of mac: BackedUpMac, password: String?) {
    setDrive(.loadingFolders)
    let backup = backup
    startRestore { [self] run in
      do {
        let folders = try await backup.backedUpFolders(of: mac, password: password)
        guard isCurrent(run) else { return }
        guard !folders.isEmpty else {
          restoreContext.retry = { self.openBackup(of: mac) }
          setDrive(
            .failed(
              RestoreProblem(
                title: "That backup holds no folders",
                message:
                  "It lists no backed-up folder yet. If \(mac.isThisMac ? "this Mac" : mac.name) only just started, try again after its first backup.",
                fix: .tryAgain)))
          return
        }
        restoreContext.password = password
        restoreContext.folders = folders
        setDrive(.folders(freshPick(folders)))
      } catch BackupBuff.Failure.passwordNeeded where isCurrent(run) {
        setDrive(.password(PasswordAsk(macName: mac.name)))
      } catch BackupBuff.Failure.passwordDoesNotOpen where isCurrent(run) {
        setDrive(.password(PasswordAsk(macName: mac.name, isWrong: true)))
      } catch {
        guard isCurrent(run) else { return }
        await failDrive(error, retry: { self.openBackup(of: mac) })
      }
    }
  }

  private func freshPick(_ folders: [BackedUpFolder]) -> FolderPick {
    FolderPick(
      folders: folders, destination: restoreContext.destination.path,
      destinationName: (restoreContext.destination.path as NSString).abbreviatingWithTildeInPath)
  }

  func selectBackedUpFolder(series: String) {
    guard case .folders(var pick)? = restoreFromDriveSheet?.step else { return }
    pick.select(series: series)
    setDrive(.folders(pick))
  }

  func selectBackedUpDate(snapshotID: String) {
    guard case .folders(var pick)? = restoreFromDriveSheet?.step else { return }
    pick.selectedSnapshotID = snapshotID
    setDrive(.folders(pick))
  }

  /// Choose…: where the restored folder goes.
  func chooseRestorePlace() {
    guard case .folders(var pick)? = restoreFromDriveSheet?.step,
      let place = NSOpenPanel.chooseFolderToRestoreInto()
    else { return }
    restoreContext.destination = place
    pick.destination = place.path
    pick.destinationName = (place.path as NSString).abbreviatingWithTildeInPath
    setDrive(.folders(pick))
  }

  /// Restore Folder: the chosen folder at the chosen date, into a new folder in the place.
  func restoreFromDrive() {
    guard case .folders(let pick)? = restoreFromDriveSheet?.step, let folder = pick.folder,
      let snapshot = pick.snapshot, let mac = restoreContext.mac
    else { return }
    let destination = URL(fileURLWithPath: pick.destination)
    let password = restoreContext.password
    let started = RestoreRun(folderName: folder.name, path: destination.path)
    restoreRun = started
    setDrive(.restoring(started))
    let (backup, name) = (backup, folder.name)
    startRestore { [self] run in
      do {
        let restored = try await backup.restore(
          snapshot, of: folder, from: mac, into: destination, password: password,
          onProgress: { progress in
            Task { @MainActor in
              self.restoreDriveDidProgress(progress, run: run, name: name, path: destination.path)
            }
          })
        guard isCurrent(run) else { return }
        restoreRun = nil
        restoreFromDriveSheet?.restored.append(
          RestoredFolder(
            name: restored.lastPathComponent, path: restored.path, source: folder,
            savedAt: snapshot.time))
        setDrive(.restored)
        NSWorkspace.shared.activateFileViewerSelecting([restored])
      } catch {
        guard isCurrent(run) else { return }
        restoreRun = nil
        await failDrive(error, retry: { self.setDrive(.folders(pick)) })
      }
    }
  }

  private func restoreDriveDidProgress(
    _ progress: RestoreProgress, run: UUID, name: String, path: String
  ) {
    guard restoreRun != nil, restoreGate.isCurrent(run),
      case .restoring = restoreFromDriveSheet?.step
    else { return }
    let current = RestoreRun(folderName: name, path: path, progress: progress)
    restoreRun = current
    setDrive(.restoring(current))
  }

  /// Restore Another Folder: to the backup's folders.
  func restoreAnotherFromDrive() {
    setDrive(.folders(freshPick(restoreContext.folders)))
  }

  /// Back, from the folders to what is restored already.
  func backToRestored() {
    setDrive(.restored)
  }

  func showRestoredFolderInFinder(_ folder: RestoredFolder) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
  }

  // MARK: - Keep Backing Up Here

  /// Keep Backing Up Here: this Mac continues the backup the restored folders came from, the
  /// newest restore of each series carrying it on; nothing is added to DirBuff unless this
  /// succeeds. The password is kept in the Keychain only then too.
  func keepBackingUpHere() {
    guard let sheet = restoreFromDriveSheet, let mac = restoreContext.mac else { return }
    setDrive(.keeping)
    let (backup, password) = (backup, restoreContext.password)
    let continuing = Dictionary(
      uniqueKeysWithValues: sheet.continuing.map { (URL(fileURLWithPath: $0.path), $0.source) })
    startRestore { [self] run in
      do {
        // The repository was listed in the Drive signed in to: that account is the backup's
        // owner from the same write.
        let owner = try await driveAccount.signedInAccount()
        try await backup.keepBackingUpHere(
          mac, password: password, continuing: continuing, as: owner)
        guard isCurrent(run) else { return }
        await refresh()
        await backupDidChange()
        guard isCurrent(run) else { return }
        setDrive(.kept)
      } catch {
        guard isCurrent(run) else { return }
        await failDrive(error, retry: { self.setDrive(.restored) })
      }
    }
  }

  // MARK: - Fixes and closing

  func fixRestoreFromDrive(_ fix: RestoreProblem.Fix) {
    switch fix {
    case .none: break
    case .chooseFolder:
      // Back to the folder and date chosen, then the place.
      restoreContext.retry?()
      chooseRestorePlace()
    case .signIn, .chooseAccount:
      closeRestoreFromDrive()
      askToSignIn(.signInAgain)
    case .enterPassword:
      guard let mac = restoreContext.mac else { return }
      setDrive(.password(PasswordAsk(macName: mac.name)))
    case .tryAgain:
      restoreContext.retry?()
    }
  }

  /// Cancel, Not Now and Done: closes the sheet, stopping a restore under way. The password
  /// typed goes with it.
  func closeRestoreFromDrive() {
    endRestore()
    restoreFromDriveSheet = nil
    restoreContext = RestoreContext()
  }

  private func setDrive(_ step: RestoreFromDriveState.Step) {
    restoreFromDriveSheet?.step = step
  }

  private func failDrive(_ error: any Error, retry: @escaping @MainActor () -> Void) async {
    logger.error("Restore from Google Drive failed: \(String(describing: error), privacy: .public)")
    restoreContext.retry = retry
    let problem = RestoreProblem(error, while: .backup)
    await noteDriveProblem(error)
    guard restoreFromDriveSheet != nil else { return }
    setDrive(.failed(problem))
  }
}
