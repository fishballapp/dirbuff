import Foundation

extension BackupBuff {
  /// **Start Again**, for a backup deleted from Drive: a new, empty repository takes the old
  /// one's place, and every Backup folder is owed a backup at once. The old history is lost for
  /// good to DirBuff, so the caller says the user knows (`confirmingHistoryIsLost`); nothing in
  /// Drive is deleted, so a backup still in the Bin stays there to be emptied or restored by hand.
  ///
  /// The new repository keeps the password the old one had, so Private Backup stays private.
  /// It is made and set up before the database switches to it, in one write: cut short, the old
  /// repository is still this Mac's, still reported gone, and Start Again can be taken again.
  ///
  /// With `owner`, the account signed in while the backup is in another's (`otherAccount`): the
  /// new backup is made in this account's Drive and becomes this Mac's, and the old one stays in
  /// the other account's Drive, untouched.
  public func startAgain(
    confirmingHistoryIsLost isConfirmed: Bool, as owner: BackupOwner? = nil, now: Date = Date()
  ) async throws {
    guard isConfirmed else { throw Failure.notConfirmed }
    try await noticingAccount {
      try await commands.run {
        let host = try store.backupAccount()?.host ?? machineID()
        let (id, repository) = try await storage.makeNewRepository()
        let session = Session(repository: repository, host: host, key: try keychain.key())
        _ = try await restic(session) { try await $0.createRepository() }
        try store.startAgainBackupRepository(repository: id, host: host, now: now, owner: owner)
      }
    }
  }
}
