import Foundation
import GRDB

/// The Google account this Mac's backup lives in: Google's ID for it, and its address for words.
public struct BackupOwner: Sendable, Equatable {
  /// `DriveAbout.accountID`: Google's permission ID for the user.
  public var accountID: String
  public var email: String

  public init(accountID: String, email: String) {
    self.accountID = accountID
    self.email = email
  }

  init(_ about: DriveAbout) {
    self.init(accountID: about.accountID, email: about.email)
  }
}

extension Store {
  /// Registered after the account's problems. A backup made before it has no owner until the
  /// next check that reaches Google adopts whoever is signed in.
  static func registerBackupOwnerMigrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("backup owner") { db in
      try db.create(table: "backupOwner") { t in
        t.primaryKey("id", .integer).check { $0 == 1 }
        t.column("accountID", .text).notNull()
        t.column("email", .text).notNull()
      }
    }
  }

  /// The account the user confirmed, or the backup was found in; nil before either.
  public func backupOwner() throws -> BackupOwner? {
    try database.read { db in
      try Row.fetchOne(db, sql: "SELECT accountID, email FROM backupOwner").map {
        BackupOwner(accountID: $0["accountID"], email: $0["email"])
      }
    }
  }

  /// The account is the backup's from now on, and nothing stands against it as another's.
  func confirmBackupOwner(_ owner: BackupOwner) throws {
    try database.write { db in try saveBackupOwner(owner, in: db) }
  }

  func saveBackupOwner(_ owner: BackupOwner, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO backupOwner (id, accountID, email) VALUES (1, ?, ?)
        ON CONFLICT (id) DO UPDATE SET accountID = excluded.accountID, email = excluded.email
        """,
      arguments: [owner.accountID, owner.email])
    for problem in [DriveAccountProblem.otherAccount, .unconfirmed] {
      try db.execute(
        sql: "DELETE FROM backupAccountProblem WHERE cause = ?", arguments: [problem.rawValue])
    }
  }
}
