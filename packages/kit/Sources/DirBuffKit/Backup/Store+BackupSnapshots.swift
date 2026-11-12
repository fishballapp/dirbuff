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
    // Since when each folder's versions are followed. A backup made before this column is taken
    // as followed from the oldest of this Mac's own backups the repository keeps.
    migrator.registerMigration("backup versions tracked since") { db in
      try db.alter(table: "backup") { t in t.add(column: "versionsTrackedSince", .datetime) }
      try fillVersionsTrackedSince(in: db)
    }
  }

  /// For a folder that doesn't know since when its versions are followed: from the oldest kept
  /// snapshot this Mac made itself (one its own History recorded), from which its backups'
  /// diffs were recorded. A series another Mac made, or none yet, stays unknown.
  static func fillVersionsTrackedSince(in db: Database) throws {
    try db.execute(
      sql: """
        UPDATE backup SET versionsTrackedSince = (
          SELECT MIN(s.savedAt) FROM backupSnapshot s
          JOIN backupRun r ON r.folderID = s.folderID AND r.snapshotID = s.snapshotID
          WHERE s.folderID = backup.folderID)
        WHERE versionsTrackedSince IS NULL
        """)
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
      let kept = try Self.keptBackups(folderID: folderID, in: db)
      let isListingPending = try Self.isListingPending(db)
      let trackedSince = try Self.versionsTrackedSince(folderID: folderID, in: db)
      return Dictionary(grouping: rows, by: \.path).map { path, versions in
        Self.history(
          of: path, versions: versions, kept: kept, trackedSince: trackedSince,
          isListingPending: isListingPending)
      }
      .sorted { $0.path < $1.path }
    }
  }

  /// One file's history, as `backupFileHistories` makes it: no versions for a file that is in
  /// every backup as the folder's first backup saved it.
  public func backupFileHistory(folderID: Int64, path: String) throws -> FileHistory {
    try database.read { db in
      let versions = try Row.fetchAll(
        db,
        sql: "SELECT * FROM backupVersion WHERE folderID = ? AND path = ? ORDER BY savedAt, id",
        arguments: [folderID, path]
      ).map(Self.backupVersion)
      return Self.history(
        of: path, versions: versions, kept: try Self.keptBackups(folderID: folderID, in: db),
        trackedSince: try Self.versionsTrackedSince(folderID: folderID, in: db),
        isListingPending: try Self.isListingPending(db))
    }
  }

  /// The backups of the folder the repository still holds, oldest first.
  public func keptBackups(folderID: Int64) throws -> [KeptBackup] {
    try database.read { try Self.keptBackups(folderID: folderID, in: $0) }
  }

  /// The names in the folder at `folder` (inside the backed-up folder, `""` for its top) that
  /// have a version recorded after `backup`: a file changed, added or deleted since, or a folder
  /// with such a file in it. One query over the folder's own rows, so it costs the same for any
  /// number of names.
  func backupNamesChanged(folderID: Int64, in folder: String, after backup: KeptBackup) throws
    -> Set<String>
  {
    let prefix = folder.isEmpty ? "" : folder + "/"
    // `path` is compared as bytes: everything starting with "a/b/" sorts from "a/b/" up to,
    // not including, "a/b0" ("0" follows "/").
    let upper = folder.isEmpty ? nil : folder + "0"
    // SQLite's substr counts characters, as Unicode scalars.
    let start = prefix.unicodeScalars.count + 1
    return try database.read { db in
      // Nothing can be newer than the newest backup: no need to read the folder's rows.
      guard
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS (SELECT 1 FROM backupSnapshot WHERE folderID = ? AND savedAt > ?)",
          arguments: [folderID, backup.savedAt]) == true
      else { return [] }
      return Set(
        try String.fetchAll(
          db,
          sql: """
            SELECT DISTINCT CASE instr(rest, '/') WHEN 0 THEN rest
              ELSE substr(rest, 1, instr(rest, '/') - 1) END
            FROM (SELECT substr(path, ?) AS rest FROM backupVersion
              WHERE folderID = ? AND savedAt > ? AND snapshotID != ? AND path >= ?
              \(upper == nil ? "" : "AND path < ?"))
            """,
          arguments: StatementArguments(
            [start, folderID, backup.savedAt, backup.id, prefix] as [any DatabaseValueConvertible]
              + (upper.map { [$0] } ?? []))))
    }
  }

  private static func keptBackups(folderID: Int64, in db: Database) throws -> [KeptBackup] {
    try Row.fetchAll(
      db,
      sql: "SELECT snapshotID, savedAt FROM backupSnapshot WHERE folderID = ? ORDER BY savedAt",
      arguments: [folderID]
    ).map { KeptBackup(id: $0["snapshotID"], savedAt: $0["savedAt"]) }
  }

  private static func versionsTrackedSince(folderID: Int64, in db: Database) throws -> Date? {
    try Date.fetchOne(
      db, sql: "SELECT versionsTrackedSince FROM backup WHERE folderID = ?",
      arguments: [folderID])
  }

  private static func isListingPending(_ db: Database) throws -> Bool {
    try Bool.fetchOne(db, sql: "SELECT isPending FROM backupSnapshotListing") ?? false
  }

  /// A file's history from its rows inside the time its versions have been followed. The content
  /// before its first recorded change is offered only from a kept snapshot inside that time too:
  /// one older may hold other content no row tells of.
  private static func history(
    of path: String, versions: [BackupVersion], kept: [KeptBackup], trackedSince: Date?,
    isListingPending: Bool
  ) -> FileHistory {
    // Rows from before the time followed (a takeover, or a diff that failed, moved the point on)
    // are of a history with a gap in it: they are left in place and not read.
    let versions = versions.filter { version in trackedSince.map { version.savedAt >= $0 } ?? false
    }
    guard let first = versions.first, first.change != .added else {
      return FileHistory(path: path, versions: versions, trackedSince: trackedSince)
    }
    // Which snapshots are kept isn't known yet: none is offered until it is.
    guard !isListingPending else {
      return FileHistory(
        path: path, versions: versions, earlierVersionIsUnknown: true, trackedSince: trackedSince)
    }
    // Its own snapshot is excluded by name: dates are stored to the millisecond.
    // Nothing of this Mac's own: no earlier content is known.
    guard let trackedSince else {
      return FileHistory(path: path, versions: versions, trackedSince: nil)
    }
    // The file was in the snapshot each first change was recorded from, which is in the time
    // followed; the newest kept from that time holds its content. None kept: thinned away.
    guard
      let before = kept.last(where: {
        $0.id != first.snapshotID && $0.savedAt < first.savedAt && $0.savedAt >= trackedSince
      })
    else {
      return FileHistory(
        path: path, versions: versions, hasEarlierVersionNotKept: true, trackedSince: trackedSince)
    }
    let earlier = BackupVersion(
      path: path, snapshotID: before.id, savedAt: before.savedAt, change: .changed, size: nil,
      replacedAt: first.savedAt)
    return FileHistory(path: path, versions: [earlier] + versions, trackedSince: trackedSince)
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

/// A backup of a folder the repository still holds: one snapshot of its series.
public struct KeptBackup: Sendable, Hashable, Identifiable {
  /// The snapshot's ID.
  public var id: String
  public var savedAt: Date

  public init(id: String, savedAt: Date) {
    self.id = id
    self.savedAt = savedAt
  }

  public init(_ snapshot: ResticSnapshot) {
    self.init(id: snapshot.id, savedAt: snapshot.time)
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
  /// Since when this Mac has followed the folder's versions: no change before then is recorded,
  /// so a snapshot older than this may hold content the history doesn't tell of. Nil until this
  /// Mac's first backup of the series.
  public var trackedSince: Date?

  public init(
    path: String, versions: [BackupVersion], hasEarlierVersionNotKept: Bool = false,
    earlierVersionIsUnknown: Bool = false, trackedSince: Date? = nil
  ) {
    self.path = path
    self.versions = versions
    self.hasEarlierVersionNotKept = hasEarlierVersionNotKept
    self.earlierVersionIsUnknown = earlierVersionIsUnknown
    self.trackedSince = trackedSince
  }
}
