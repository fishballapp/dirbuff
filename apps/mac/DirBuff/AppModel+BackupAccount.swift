import AppKit
import DirBuffKit
import DirBuffUI
import Foundation
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "backup")

/// The states of the Google account Backup uses, and the fixes that need no window of their own.
///
/// `DriveAccount` in kit finds the states (the hourly check, the look before each run, a failed
/// command) and keeps them in the database; this reads them into `DriveState`, holds Backup's
/// runs while one stands and carries out the fixes. **Sign In Again…** is the sign-in sheet's:
/// it calls `googleSignIn.signIn()`, then `googleDidSignIn()`.
extension AppModel {
  /// Where **Make Room…** goes: Google One's page for the account's storage.
  nonisolated static let googleStorageURL = URL(string: "https://one.google.com/storage")

  var driveAccount: DriveAccount {
    DriveAccount(drive: DriveClient(tokens: googleSignIn), store: engine.store)
  }

  /// Nothing is backed up or kept up while the account can't be used, or isn't confirmed yet; the
  /// hourly check goes on and lets go of the hold when its cause is gone.
  var isAccountHeld: Bool {
    switch driveState {
    case .signedOut, .otherAccount, .notSignedIn, .full, .backupGone, .backupInBin: true
    case .ready, .partMissing, .waiting: false
    }
  }

  /// Whether nothing may be backed up until the user confirms the account on the sign-in sheet.
  func isAwaitingAccountConfirmation() -> Bool {
    do {
      return try driveAccount.isAwaitingConfirmation()
    } catch {
      logger.error(
        "Couldn't read the account's owner: \(error.localizedDescription, privacy: .public)")
      return true
    }
  }

  /// The account's problem to fix first, as the state every surface shows; nil if there is none.
  /// A signed-out account has no token left, and would otherwise read as one never signed in.
  func accountDriveState() -> DriveState? {
    let problems: [DriveAccountProblem: Date]
    do {
      problems = try engine.store.accountProblems()
    } catch {
      logger.error(
        "Couldn't read the account's problems: \(error.localizedDescription, privacy: .public)")
      return nil
    }
    guard let first = DriveAccountProblem.allCases.first(where: { problems[$0] != nil }) else {
      return nil
    }
    return switch first {
    case .signedOut: .signedOut
    case .otherAccount:
      .otherAccount(owner: (try? engine.store.backupOwner()?.email) ?? "another account")
    // Signed in, waiting for Start Backup: as the row says, waiting for Google sign-in.
    case .unconfirmed: .notSignedIn
    case .backupGone: .backupGone
    case .backupInBin: .backupInBin
    case .full: .full
    }
  }

  /// A token refresh, `about.get` and a look at the backup in Drive. Only Google's answers set a
  /// state: no answer (offline) leaves them as they are.
  func checkBackupAccount() async {
    guard await isSignedIn() else { return }
    do {
      try await driveAccount.check()
    } catch {
      logger.error(
        "Couldn't check the Google account: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// After something changed the account's states: the folders, the status file and the
  /// notifications read them afresh, and Backup's runs, which waited, start if the state has gone.
  func backupAccountDidChange() async {
    await refresh()
    await backupDidChange()
  }

  // MARK: - The fixes

  /// **Sign In Again…**, when the sheet has signed in: looks at the account afresh, so the state
  /// clears and Backup goes on at once, not at the next hourly check.
  func googleDidSignIn() async {
    await checkBackupAccount()
    await backupAccountDidChange()
  }

  /// After Sign Out: there is no account left to have problems, and the Mac is just not signed in.
  func googleDidSignOut() async {
    do {
      try engine.store.clearAllAccountProblems()
    } catch {
      logger.error(
        "Couldn't forget the account's problems: \(error.localizedDescription, privacy: .public)")
    }
    await backupAccountDidChange()
  }

  /// **Put Back**: the backup out of Drive's Bin.
  func putBackBackup() async {
    do {
      try await driveAccount.putBack()
    } catch {
      show(error, doing: "put the backup back")
    }
    await backupAccountDidChange()
  }

  /// **Start Again…**: a new backup in Drive in place of the one that is gone. The old history is
  /// lost, so the caller must have asked the user, and says so with `confirmingHistoryIsLost`.
  func startAgain(confirmingHistoryIsLost isConfirmed: Bool) async {
    let backup = backup
    do {
      try await backup.startAgain(confirmingHistoryIsLost: isConfirmed)
    } catch {
      show(error, doing: "start the backup again")
    }
    await backupAccountDidChange()
  }

  /// **Make Room…**: Google One's page, where the user frees or buys storage. The next hourly
  /// check sees the room.
  func makeRoom() {
    guard let url = Self.googleStorageURL else { return }
    NSWorkspace.shared.open(url)
  }
}
