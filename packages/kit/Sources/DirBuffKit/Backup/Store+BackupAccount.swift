import Foundation
import GRDB

/// What stops Backup using the Google account, apart from the network: each is a state the
/// surfaces show and a fix the user takes, and each clears itself once its cause is gone.
/// Listed by how much a user must do first: nothing else can be fixed while signed out, and a
/// full Drive is no use to a backup that is gone.
public enum DriveAccountProblem: String, Sendable, Equatable, Hashable, CaseIterable {
  /// Google no longer honours DirBuff's access (`invalid_grant`).
  case signedOut
  /// The account signed in isn't the one this Mac's backup lives in (`Store.backupOwner`).
  case otherAccount
  /// Signed in, but the user hasn't yet confirmed the account, and there is no backup to say
  /// whose it is: nothing is backed up or made in Drive until they do.
  case unconfirmed
  /// The repository's folder, or its `config`, is deleted from Drive.
  case backupGone
  /// The repository's folder, or its `config`, is in Drive's Bin.
  case backupInBin
  /// Drive is full or within `DriveAccount.roomNeeded` of it.
  case full
}

extension Store {
  /// Registered after the notifications': the account's problems outlive a relaunch, since a
  /// signed-out account has no token left to find out from, and the next check may be an hour
  /// away.
  static func registerBackupAccountMigrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("backup account problems") { db in
      try db.create(table: "backupAccountProblem") { t in
        t.primaryKey("cause", .text)
        t.column("since", .datetime).notNull()
      }
      // Never written: `backupAccount` exists only once a repository does, and a signed-out
      // account may have none.
      try db.alter(table: "backupAccount") { t in
        t.drop(column: "signedOutSince")
        t.drop(column: "fullSince")
      }
    }
  }

  /// What is wrong with the account now, and since when.
  public func accountProblems() throws -> [DriveAccountProblem: Date] {
    try database.read { db in
      try Row.fetchAll(db, sql: "SELECT cause, since FROM backupAccountProblem").reduce(into: [:]) {
        problems, row in
        if let cause = DriveAccountProblem(rawValue: row["cause"]) {
          problems[cause] = row["since"]
        }
      }
    }
  }

  /// The problem begins at `date`; one that stands already keeps its earlier date.
  func recordAccountProblem(_ problem: DriveAccountProblem, at date: Date) throws {
    try database.write {
      try $0.execute(
        sql: "INSERT INTO backupAccountProblem (cause, since) VALUES (?, ?) ON CONFLICT DO NOTHING",
        arguments: [problem.rawValue, date])
    }
  }

  func clearAccountProblems(_ problems: [DriveAccountProblem]) throws {
    try database.write { db in
      for problem in problems {
        try db.execute(
          sql: "DELETE FROM backupAccountProblem WHERE cause = ?", arguments: [problem.rawValue])
      }
    }
  }

  /// Signing out for good leaves no account to have problems.
  public func clearAllAccountProblems() throws {
    try clearAccountProblems(DriveAccountProblem.allCases)
  }

  /// Forgets that `DirBuff Backup` was ever found or made, for one that is gone from Drive.
  func clearBackupDriveFolder() throws {
    try database.write { try $0.execute(sql: "UPDATE backupDrive SET backupsFolderID = NULL") }
  }

  /// Start Again: `repository` (the storage's ID for it, an empty one the database doesn't know
  /// yet) becomes this Mac's, in one write, and nothing the database recorded of the old
  /// repository is left to be mistaken for the new one's. The folders keep their series and their
  /// settings; each is owed a backup at once, as when Backup first went on. History's runs stay.
  ///
  /// With `owner`, the new repository is that account's: Start a New Backup in another account.
  func startAgainBackupRepository(
    repository: String, host: String, now: Date, owner: BackupOwner? = nil
  ) throws {
    try database.write { db in
      if let old = try String.fetchOne(
        db, sql: "SELECT repositoryFolderID FROM backupDrive WHERE id = 1")
      {
        try db.execute(sql: "DELETE FROM repositoryFile WHERE repositoryID = ?", arguments: [old])
      }
      try db.execute(
        sql: """
          INSERT INTO backupDrive (id, repositoryFolderID) VALUES (1, ?)
          ON CONFLICT (id) DO UPDATE SET repositoryFolderID = excluded.repositoryFolderID
          """,
        arguments: [repository])
      try db.execute(sql: "DELETE FROM backupAccount")
      try db.execute(
        sql: "INSERT INTO backupAccount (id, host, createdAt) VALUES (1, ?, ?)",
        arguments: [host, now])
      try db.execute(
        sql: """
          UPDATE backup SET lastRunAt = ?, lastSuccessAt = NULL, lastSnapshotID = NULL,
            lastError = NULL, failingSince = NULL, failedRunsInARow = 0, lastForgetAt = NULL,
            cloudOnlyCount = 0
          """,
        arguments: [now])
      try db.execute(sql: "DELETE FROM backupSkipped")
      try db.execute(sql: "DELETE FROM backupVersion")
      try db.execute(sql: "DELETE FROM backupDeletion")
      try db.execute(
        sql: "DELETE FROM backupAccountProblem WHERE cause IN (?, ?)",
        arguments: [
          DriveAccountProblem.backupGone.rawValue, DriveAccountProblem.backupInBin.rawValue,
        ])
      if let owner { try saveBackupOwner(owner, in: db) }
    }
  }
}
