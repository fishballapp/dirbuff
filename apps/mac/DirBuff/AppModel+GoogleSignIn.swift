import AppKit
import DirBuffKit
import DirBuffUI
import Foundation
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "backup")

/// The Google sign-in sheet's steps, over `GoogleSignIn` (the loopback flow with PKCE). The sheet
/// is on the main window; signing in stores the token, and Start Backup lets Backup's driver
/// follow the folders.
extension AppModel {
  /// Opens the sheet on the main window, unless one is open already. Signed in already (the
  /// account not yet confirmed, or not the backup's), it opens at the account step.
  func askToSignIn(_ reason: GoogleSignInState.Reason) {
    guard signInSheet == nil else { return }
    signInSheet = GoogleSignInState(reason: reason, step: isSignedInToGoogle ? .waiting : .ask)
    if isSignedInToGoogle {
      signInTask?.cancel()
      signInTask = Task { await showAccountStep() }
    }
  }

  /// Sign In with Google… and Try Again…: opens Google's sign-in in the browser and waits.
  func signInWithGoogle() {
    guard signInSheet != nil else { return }
    setSignInStep(.waiting)
    signInTask?.cancel()
    signInTask = Task { await signInThenShowAccount() }
  }

  private func signInThenShowAccount() async {
    do {
      try await googleSignIn.signIn()
    } catch is CancellationError {
      return
    } catch {
      logger.error("Google sign-in failed: \(error.localizedDescription, privacy: .public)")
      setSignInStep(.failed(Self.explain(error)))
      return
    }
    googleAccount = nil
    await showAccountStep()
  }

  /// After a sign-in: the account's states are looked at again at once (signed out clears), and
  /// the sheet names the account, or says the backup is in another's Drive. Nothing is backed up
  /// yet: the account isn't confirmed until Start Backup.
  private func showAccountStep() async {
    await googleDidSignIn()
    if googleAccount == nil { await readGoogleAccount() }
    guard !Task.isCancelled else { return }
    // Restoring reads the account signed in, whoever owns this Mac's own backup.
    if signInSheet?.reason != .restore, case .otherAccount(let owner) = driveState {
      setSignInStep(.otherAccount(owner: owner, signedIn: googleAccount))
    } else {
      setSignInStep(.signedIn(account: googleAccount))
    }
  }

  /// Not Now, and Cancel while the browser is open: Backup waits for a sign-in, or for the
  /// account to be confirmed.
  func dismissSignIn() {
    signInTask?.cancel()
    signInTask = nil
    signInSheet = nil
    Task { await refresh() }
  }

  /// Start Backup, Carry On and Done: the account signed in is the backup's from now on, and the
  /// folders are followed. Refused if the backup is in another account's Drive, which the sheet
  /// then says.
  func confirmSignIn() {
    guard let sheet = signInSheet else { return }
    signInSheet = nil
    // Restore from Google Drive… asked for the sign-in, and goes on with it: restoring another
    // Mac's backup needs no confirmed account, and nothing is backed up.
    if sheet.reason == .restore {
      Task { await refresh() }
      openRestoreFromDrive()
      return
    }
    Task {
      do {
        try await driveAccount.confirmSignedInAccount()
      } catch DriveAccount.Failure.backupInAnotherAccount {
        signInSheet = sheet
        await showAccountStep()
        return
      } catch {
        show(error, doing: "use this Google account")
      }
      await backupAccountDidChange()
      // A backup that needs the user says so in a notification: asked when that becomes useful,
      // as the first Temporary folder asks. macOS asks only once.
      requestNotificationPermission()
    }
  }

  /// Use Another Account…: forgets this one and asks Google again. The sheet leaves the account
  /// step before anything is awaited, so it can't be confirmed meanwhile.
  func useAnotherGoogleAccount() {
    setSignInStep(.waiting)
    signInTask?.cancel()
    signInTask = Task {
      do {
        try await googleSignIn.signOut()
      } catch {
        logger.error("Couldn't sign out: \(error.localizedDescription, privacy: .public)")
      }
      googleAccount = nil
      await googleDidSignOut()
      await signInThenShowAccount()
    }
  }

  /// Start a New Backup Here…, after asking: a new backup in the account signed in becomes this
  /// Mac's, and the old one stays in the other account's Drive.
  func startNewBackupHere() {
    guard let sheet = signInSheet, case .otherAccount(let owner, let signedIn) = sheet.step
    else { return }
    let alert = BackupAlert.startNewBackup(owner: owner, signedIn: signedIn ?? "this account")
      .makeAlert()
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    signInSheet = nil
    let backup = backup
    Task {
      do {
        let account = try await driveAccount.signedInAccount()
        try await backup.startAgain(confirmingHistoryIsLost: true, as: account)
      } catch {
        show(error, doing: "start a new backup")
      }
      await backupAccountDidChange()
    }
  }

  private func setSignInStep(_ step: GoogleSignInState.Step) {
    guard var sheet = signInSheet else { return }
    sheet.step = step
    signInSheet = sheet
  }
}
