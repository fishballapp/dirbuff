import AppKit
import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "backup")

/// What Backup's surfaces need from the app: putting it on and taking it off, its setting, its
/// card's latest backups, Show Details, and Settings › Backup (the account and the password).
extension AppModel {
  /// After the folders are read: whether DirBuff holds a Google sign-in, the account's address,
  /// whether the backup has a password, and each Backup folder's latest backups.
  func refreshBackupSurfaces() async {
    isSignedInToGoogle = (try? await googleSignIn.isSignedIn()) ?? false
    if !isSignedInToGoogle { googleAccount = nil }
    let backup = backup
    let store = engine.store
    let ids = reports.filter { $0.backupWear != nil }.compactMap(\.folder.id)
    let read = await Task.detached {
      let attempts = Dictionary(
        uniqueKeysWithValues: ids.map { id in
          (id, (try? store.backupAttempts(folderID: id, limit: 5)) ?? [])
        })
      return (attempts, (try? backup.isPasswordProtected()) ?? false)
    }.value
    backupAttempts = read.0
    isBackupPasswordProtected = read.1
    if isSignedInToGoogle, googleAccount == nil { await readGoogleAccount() }
    // A buff dropped on a tile gets its card; Backup only once there is an account to name.
    AddBuffHost.shared.backupAccount =
      isSignedInToGoogle && !isAwaitingAccountConfirmation()
      ? (try? engine.store.backupOwner()?.email) ?? googleAccount : nil
  }

  /// Asks Google which account DirBuff is signed in to (`about.get`, 5 units). Offline, the
  /// surfaces say "your Google Drive" until the next refresh asks again.
  func readGoogleAccount() async {
    do {
      googleAccount = try await DriveClient(tokens: googleSignIn).about().email
    } catch {
      logger.info(
        "Couldn't read the Google account: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - On and off

  /// Puts Backup on the folder, or takes it off keeping its backup; returns whether that
  /// happened. Put on while signed out, it waits, and the sign-in sheet asks.
  @discardableResult
  func setBackup(_ folder: Folder, _ isOn: Bool) async -> Bool {
    guard let folderID = folder.id else { return false }
    let backup = backup
    let name = URL(fileURLWithPath: folder.path).lastPathComponent
    do {
      try await Task.detached {
        if isOn {
          try backup.putOn(folderID: folderID)
        } else {
          try backup.takeOff(folderID: folderID)
        }
      }.value
    } catch {
      show(error, doing: isOn ? "back up \(name)" : "take Backup off \(name)")
      await refresh()
      return false
    }
    await refresh()
    if isOn, !isSignedInToGoogle || isAwaitingAccountConfirmation() {
      // The sheet is the main window's; from Finder, the window opens at the folder first.
      showMain(nil)
      askToSignIn(.backUp(folderName: name, folderPath: folder.path))
    } else if isOn {
      // Signed in already: Backup's needs-you notifications are useful from now on.
      requestNotificationPermission()
    }
    return true
  }

  /// Take Off for Backup, after asking: new changes stop going to Drive, and the backup stays
  /// there unless the box to delete it is ticked.
  func confirmTakeBackupOff(folderID: Int64) async {
    guard let folder = folder(id: folderID) else { return }
    let name = URL(fileURLWithPath: folder.path).lastPathComponent
    let alert = BackupAlert.takeOff(folderName: name).makeAlert()
    // From Finder, DirBuff isn't the active app, and its alert would open behind Finder.
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let isDeletingBackup = alert.suppressionButton?.state == .on
    let backup = backup
    do {
      try await Task.detached {
        try backup.takeOff(folderID: folderID, isDeletingBackup: isDeletingBackup)
      }.value
    } catch {
      show(error, doing: "take Backup off \(name)")
    }
    await refresh()
  }

  /// The card's history pop-up; a shorter history is confirmed on the card first.
  func save(_ settings: BackupSettings, folderID: Int64) async {
    let backup = backup
    do {
      try await Task.detached { try backup.save(settings, folderID: folderID) }.value
    } catch {
      show(error, doing: "save the folder's settings")
    }
    await refresh()
  }

  // MARK: - Show Details

  /// What the weekly check found missing, or the last failed backup's whole error.
  func showBackupDetails(folderID: Int64) {
    showFolderPage(folderID)
    let backup = backup
    Task {
      let check = try? await Task.detached { try backup.lastCheck() }.value
      let report = report(id: folderID)
      let name =
        report.map { URL(fileURLWithPath: $0.folder.path).lastPathComponent } ?? "This folder"
      if let problem = check?.problem {
        alert(
          "Part of the backup is missing",
          "The weekly check found this:\n\n\(problem)\n\nSome versions may not restore. Backups carry on, and the next check looks again."
        )
      } else if let error = report?.backupStatus?.lastError {
        alert(
          "Why backups of \(name) are failing",
          "The last backup stopped with this:\n\n\(error)\n\nDirBuff tries again every hour, and Back Up Now tries at once."
        )
      } else {
        alert(
          "Nothing to show",
          "The last backup of \(name) finished, and the last check found the backup whole.")
      }
    }
  }

  /// **Start Again…**, after asking: the backup in Drive is gone, and a new one starts without its
  /// history.
  func confirmStartAgain() async {
    let alert = BackupAlert.startAgain.makeAlert()
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    await startAgain(confirmingHistoryIsLost: true)
  }

  /// After **Make Room…**: back in DirBuff while Drive is full, the account is checked again,
  /// so the folders carry on without waiting for the hourly check. At most once a minute.
  func checkForRoomIfFull(now: Date = Date()) {
    guard driveState == .full else { return }
    if let last = lastRoomCheckAt, now.timeIntervalSince(last) < 60 { return }
    lastRoomCheckAt = now
    Task {
      await checkBackupAccount()
      await backupAccountDidChange()
    }
  }

  // MARK: - Bring Back

  /// **Bring Back**: what the user left out goes into the folder's next backups again.
  func bringBack(_ item: LeaveOut, folderID: Int64) async {
    let backup = backup
    do {
      try await Task.detached { try backup.bringBack(item, folderID: folderID) }.value
    } catch {
      show(error, doing: "bring it back into the backup")
    }
    await refresh()
    await writeBackupStatus()
  }

  // MARK: - Settings › Backup

  /// Sign Out…, after asking: backups stop until a sign-in, and the backup in Drive stays.
  func signOutOfGoogle() async {
    let alert = NSAlert()
    alert.messageText = "Sign out of Google Drive?"
    alert.informativeText =
      "Backups stop until you sign in again. The backup in your Drive stays where it is."
    alert.addButton(withTitle: "Sign Out")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try await googleSignIn.signOut()
    } catch {
      show(error, doing: "sign out of Google Drive")
    }
    googleAccount = nil
    await googleDidSignOut()
  }

  /// Protect with a Password… and Change Password…; returns why not, for the sheet to show.
  /// Settings reads the backup afresh either way: a change that failed after the Keychain took
  /// the new password is pending, and the backup is protected by it.
  func setBackupPassword(_ password: String) async -> String? {
    let backup = backup
    do {
      try await Task.detached { try await backup.setPassword(password) }.value
    } catch {
      logger.error("Couldn't set the password: \(error.localizedDescription, privacy: .public)")
      await refresh()
      return Self.explain(error)
    }
    await refresh()
    return nil
  }

  /// Whether the Keychain holds `password` as the backup's: a change cut short after it did is
  /// finished by the next command.
  func keychainHoldsBackupPassword(_ password: String) -> Bool {
    (try? backup.keychain.key()) == password
  }

  /// Remove Password…, after asking.
  func removeBackupPassword() async {
    let alert = NSAlert()
    alert.messageText = "Remove the backup's password?"
    alert.informativeText =
      "The backup then opens with no password: anyone who can open your Google account can read it. Nothing uploads again."
    alert.addButton(withTitle: "Remove Password")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let backup = backup
    do {
      try await Task.detached { try await backup.removePassword() }.value
    } catch {
      // Cut short after the Keychain let go of it, the next command finishes the removal.
      if (try? backup.keychain.key()) == nil {
        self.alert(
          "The password is removed",
          "Google Drive couldn't finish the change just now, so the next backup finishes it. The backup already opens with no password."
        )
      } else {
        self.alert("Couldn't remove the password", Self.explain(error))
      }
    }
    await refresh()
  }
}
