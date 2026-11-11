import Foundation
import GRDB

/// The snapshots of a folder's series that the repository still holds, as far as the database
/// knows: one row for each backup, and what `forget` kept after each forget. A version of a file
/// is the content one snapshot holds; the version *before* the first change recorded for a file is
/// the content of the newest snapshot kept from before that change.
extension Store {
  /// Registered after the owner's. A backup made before it has no list of the snapshots the
  /// repository holds, and the runs it recorded include snapshots `forget` has removed since, so
  /// nothing is read back from them: the list is marked as still to be made, and the next command
  /// that opens the repository makes it from restic's own listing (`BackupBuff.listSnapshots`).
  static func registerBackupSnapshotMigrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("backup snapshots") { db in
      try db.create(table: "backupSnapshot") { t in
        t.column("folderID", .integer).notNull()
          .references("backup", column: "folderID", onDelete: .cascade)
        t.column("snapshotID", .text).notNull()
        t.column("savedAt", .datetime).notNull()
        t.primaryKey(["folderID", "snapshotID"])
      }
      try db.create(table: "backupSnapshotListing") { t in
        t.primaryKey("id", .integer).check { $0 == 1 }
        t.column("isPending", .boolean).notNull()
      }
      try db.execute(
        sql: """
          INSERT INTO backupSnapshotListing (id, isPending) VALUES (1,
            EXISTS (SELECT 1 FROM backupVersion)
            OR EXISTS (SELECT 1 FROM backup WHERE lastSnapshotID IS NOT NULL))
          """)
    }
  }

  /// Every file of the folder that has a past, with the versions the backup can restore. Its first
  /// recorded change is from the snapshot before: when that change is a change or a deletion, the
  /// file existed then, and the newest snapshot kept from before it holds that earlier content,
  /// which is listed as a version of its own. When none is kept (`forget` thinned them away), the
  /// history says so instead.
  public func backupFileHistories(folderID: Int64) throws -> [FileHistory] {
    try database.read { db in
      let rows = try Row.fetchAll(
        db, sql: "SELECT * FROM backupVersion WHERE folderID = ? ORDER BY savedAt, id",
        arguments: [folderID]
      ).map(Self.backupVersion)
      let snapshots = try Row.fetchAll(
        db,
        sql: "SELECT snapshotID, savedAt FROM backupSnapshot WHERE folderID = ? ORDER BY savedAt",
        arguments: [folderID]
      ).map { (id: $0["snapshotID"] as String, savedAt: $0["savedAt"] as Date) }
      let isListingPending =
        try Bool.fetchOne(
          db, sql: "SELECT isPending FROM backupSnapshotListing") ?? false
      return Dictionary(grouping: rows, by: \.path).map { path, versions in
        guard let first = versions.first, first.change != .added else {
          return FileHistory(path: path, versions: versions, hasEarlierVersionNotKept: false)
        }
        // Which snapshots are kept isn't known yet: none is offered until it is.
        guard !isListingPending else {
          return FileHistory(path: path, versions: versions, earlierVersionIsUnknown: true)
        }
        // Its own snapshot is excluded by name: dates are stored to the millisecond.
        guard
          let before = snapshots.last(where: {
            $0.id != first.snapshotID && $0.savedAt < first.savedAt
          })
        else {
          return FileHistory(path: path, versions: versions, hasEarlierVersionNotKept: true)
        }
        let earlier = BackupVersion(
          path: path, snapshotID: before.id, savedAt: before.savedAt, change: .changed, size: nil,
          replacedAt: first.savedAt)
        return FileHistory(
          path: path, versions: [earlier] + versions, hasEarlierVersionNotKept: false)
      }
      .sorted { $0.path < $1.path }
    }
  }

  /// The snapshot IDs the database holds for the folder, oldest first.
  func backupSnapshotIDs(folderID: Int64) throws -> [String] {
    try database.read { db in
      try String.fetchAll(
        db, sql: "SELECT snapshotID FROM backupSnapshot WHERE folderID = ? ORDER BY savedAt",
        arguments: [folderID])
    }
  }

  func recordBackupSnapshot(
    folderID: Int64, snapshotID: String, savedAt: Date, in db: Database
  ) throws {
    try db.execute(
      sql: "INSERT OR REPLACE INTO backupSnapshot (folderID, snapshotID, savedAt) VALUES (?, ?, ?)",
      arguments: [folderID, snapshotID, savedAt])
  }

  /// After `forget`: only the snapshots it kept are still in the repository.
  func keepBackupSnapshots(_ kept: [ResticSnapshot], folderID: Int64, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM backupSnapshot WHERE folderID = ?\(Self.notIn(kept.count))",
      arguments: StatementArguments([folderID] + kept.map(\.id)))
    for snapshot in kept {
      try db.execute(
        sql:
          "INSERT OR IGNORE INTO backupSnapshot (folderID, snapshotID, savedAt) VALUES (?, ?, ?)",
        arguments: [folderID, snapshot.id, snapshot.time])
    }
  }

  private static func notIn(_ count: Int) -> String {
    count == 0
      ? ""
      : " AND snapshotID NOT IN (\(Array(repeating: "?", count: count).joined(separator: ", ")))"
  }
}

/// A file with a past: its versions, oldest first, each one a snapshot restic holds that has the
/// file in it.
public struct FileHistory: Sendable, Equatable {
  public var path: String
  public var versions: [BackupVersion]
  /// The file existed before its first recorded change, but no snapshot from before it is kept.
  public var hasEarlierVersionNotKept: Bool
  /// The file existed before its first recorded change, but the snapshots the repository holds
  /// haven't been listed yet (after an upgrade, or a repository taken over), so whether an
  /// earlier version is kept isn't known.
  public var earlierVersionIsUnknown = false

  public init(
    path: String, versions: [BackupVersion], hasEarlierVersionNotKept: Bool = false,
    earlierVersionIsUnknown: Bool = false
  ) {
    self.path = path
    self.versions = versions
    self.hasEarlierVersionNotKept = hasEarlierVersionNotKept
    self.earlierVersionIsUnknown = earlierVersionIsUnknown
  }
}
