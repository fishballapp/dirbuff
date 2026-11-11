import Foundation

/// Which Google account this Mac's backup lives in (`Store.backupOwner`). Remembered when the
/// user confirms the account on the sign-in sheet, or, for a backup made before DirBuff
/// remembered it, adopted at the next check that reaches Google. Signed in as anyone else, the
/// backup isn't looked at, so it can't read as gone, and nothing is backed up.
extension DriveAccount {
  public enum Failure: Error, Equatable {
    /// This Mac's backup is in another account's Drive: confirming this one would leave it.
    case backupInAnotherAccount
  }

  /// The account signed in, as Google says (`about.get`).
  public func signedInAccount() async throws -> BackupOwner {
    BackupOwner(try await drive.about())
  }

  /// **Start Backup** / **Done** on the sign-in sheet: the account signed in is the one to back
  /// up to from now on. Refused while this Mac's backup is in another account's Drive: that
  /// takes Start a New Backup, which says what is left behind.
  @discardableResult
  public func confirmSignedInAccount() async throws -> BackupOwner {
    let owner = try await signedInAccount()
    if let kept = try store.backupOwner(), kept.accountID != owner.accountID,
      try store.backupDriveFolders().repository != nil
    {
      throw Failure.backupInAnotherAccount
    }
    try store.confirmBackupOwner(owner)
    return owner
  }

  /// Whether `about`'s account may be backed up to, recording why not: it is the owner, or the
  /// owner is adopted (a backup with none), or there's nothing yet to back up to and the user
  /// confirms first. Returns whether the repository is this account's to look at.
  func settleOwner(_ about: DriveAbout) throws -> Bool {
    let signedIn = BackupOwner(about)
    let hasRepository = try store.backupDriveFolders().repository != nil
    guard let owner = try store.backupOwner() else {
      guard hasRepository else {
        try store.recordAccountProblem(.unconfirmed, at: now())
        return false
      }
      try store.confirmBackupOwner(signedIn)
      return true
    }
    if owner.accountID == signedIn.accountID {
      try store.clearAccountProblems([.otherAccount, .unconfirmed])
      return true
    }
    if hasRepository {
      try store.clearAccountProblems([.unconfirmed])
      try store.recordAccountProblem(.otherAccount, at: now())
    } else {
      // Nothing was backed up to the owner's Drive: there's nothing of theirs to keep, but the
      // user says which account to use first.
      try store.clearAccountProblems([.otherAccount])
      try store.recordAccountProblem(.unconfirmed, at: now())
    }
    return false
  }

  /// Whether nothing may be backed up until the user confirms an account: none is confirmed and
  /// no backup exists, or the last check found the one signed in unconfirmed. Read locally.
  public func isAwaitingConfirmation() throws -> Bool {
    if try store.backupOwner() == nil, try store.backupDriveFolders().repository == nil {
      return true
    }
    return try store.accountProblems()[.unconfirmed] != nil
  }

  /// Whether the account signed in isn't the backup's, or isn't confirmed, as last found.
  func isElsewhere() throws -> Bool {
    let problems = try store.accountProblems()
    return problems[.otherAccount] != nil || problems[.unconfirmed] != nil
  }
}
