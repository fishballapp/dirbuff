import DirBuffCore
import Foundation
import GRDB

/// Backup's tables. `backup` has a row per folder that wears it, its setting as a column; what
/// hangs off that row (left out, skipped, versions) goes with it on Take Off. History's detail of
/// each run (`backupRun`) hangs off the run instead, and the Mac's one repository off
/// `backupAccount`.
extension Store {
  static func registerBackupMigrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("backup") { db in
      try db.create(table: "backupAccount") { t in
        // One row: the Mac's repository, created on first use.
        t.primaryKey("id", .integer).check { $0 == 1 }
        // What this Mac's snapshots are taken as (`--host`). Kept, not derived, so a new Mac can
        // take over an old one's backup.
        t.column("host", .text).notNull()
        t.column("keyCustody", .text).notNull()
        t.column("email", .text)
        t.column("driveFolderID", .text)
        t.column("repositoryDriveID", .text)
        t.column("signedOutSince", .datetime)
        t.column("fullSince", .datetime)
        t.column("lastPrunedAt", .datetime)
        t.column("createdAt", .datetime).notNull()
      }
      try db.create(table: "backup") { t in
        t.primaryKey("folderID", .integer).references("folder", onDelete: .cascade)
        // The folder's series in the repository (`--tag folder=<tag>`); a new one each time
        // Backup goes on.
        t.column("tag", .text).notNull().unique()
        t.column("history", .text).notNull()
        t.column("pausedByLicence", .boolean).notNull().defaults(to: false)
        // When it last ran, or went on.
        t.column("lastRunAt", .datetime).notNull()
        t.column("lastSuccessAt", .datetime)
        t.column("lastSnapshotID", .text)
        t.column("lastError", .text)
        t.column("failingSince", .datetime)
        t.column("failedRunsInARow", .integer).notNull().defaults(to: 0)
        t.column("lastForgetAt", .datetime)
        // The FSEvents event the folder is backed up to.
        t.column("eventID", .integer)
        // Files left out because they are only in iCloud: reading one would download it.
        t.column("cloudOnlyCount", .integer).notNull().defaults(to: 0)
      }
      try db.create(table: "backupLeftOut") { t in
        t.column("folderID", .integer).notNull()
          .references("backup", column: "folderID", onDelete: .cascade)
        t.column("kind", .text).notNull()
        t.column("value", .text).notNull()
        t.primaryKey(["folderID", "kind", "value"])
      }
      try db.create(table: "backupSkipped") { t in
        t.column("folderID", .integer).notNull()
          .references("backup", column: "folderID", onDelete: .cascade)
        t.column("path", .text).notNull()
        t.column("reason", .text).notNull()
        t.primaryKey(["folderID", "path"])
      }
      try db.create(table: "backupVersion") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("folderID", .integer).notNull()
          .references("backup", column: "folderID", onDelete: .cascade)
        t.column("path", .text).notNull()
        t.column("snapshotID", .text).notNull().indexed()
        t.column("savedAt", .datetime).notNull()
        t.column("change", .text).notNull()
        t.column("size", .integer)
      }
      try db.create(
        index: "backupVersion_on_folderID_path", on: "backupVersion", columns: ["folderID", "path"])
      try db.create(table: "backupRun") { t in
        t.column("runID", .integer).notNull().references("run", onDelete: .cascade)
        t.column("folderID", .integer).notNull().indexed()
          .references("folder", onDelete: .cascade)
        t.column("snapshotID", .text)
        t.column("filesNew", .integer).notNull().defaults(to: 0)
        t.column("filesChanged", .integer).notNull().defaults(to: 0)
        t.column("bytesAdded", .integer).notNull().defaults(to: 0)
        t.column("skippedCount", .integer).notNull().defaults(to: 0)
        t.column("error", .text)
        t.column("endedAt", .datetime).notNull()
        t.primaryKey(["runID", "folderID"])
      }
      // A folder's series to delete from the repository: Backup came off it with "also delete
      // its backup". It stays listed until the snapshots are forgotten and pruned.
      try db.create(table: "backupDeletion") { t in
        t.primaryKey("tag", .text)
      }
    }
  }

  // MARK: Wear

  func backupWear(folderID: Int64) throws -> Wear<BackupSettings>? {
    try database.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM backup WHERE folderID = ?", arguments: [folderID])
        .map(Self.backupWear)
    }
  }

  func backupWearers() throws -> [Wear<BackupSettings>] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT backup.* FROM backup JOIN folder ON folder.id = backup.folderID
          ORDER BY folder.createdAt, folder.id
          """
      ).map(Self.backupWear)
    }
  }

  /// Puts Backup on with `settings` and a new series, or, on a folder that wears it already,
  /// keeps both and lifts a licence pause.
  func putOnBackup(folderID: Int64, settings: BackupSettings, now: Date) throws {
    try database.write {
      try $0.execute(
        sql: """
          INSERT INTO backup (folderID, tag, history, lastRunAt) VALUES (?, ?, ?, ?)
          ON CONFLICT (folderID) DO UPDATE SET pausedByLicence = 0
          """,
        arguments: [folderID, UUID().uuidString.lowercased(), settings.history.rawValue, now])
    }
  }

  func saveBackupSettings(_ settings: BackupSettings, folderID: Int64) throws {
    try database.write {
      try $0.execute(
        sql: "UPDATE backup SET history = ? WHERE folderID = ?",
        arguments: [settings.history.rawValue, folderID])
    }
  }

  /// Forgets the folder's settings, what it left out and its versions. With `isDeletingBackup`,
  /// lists its series for deletion in the same write, so nothing is left in the repository that
  /// no folder names.
  func takeOffBackup(folderID: Int64, isDeletingBackup: Bool) throws {
    try database.write { db in
      if isDeletingBackup {
        try db.execute(
          sql: """
            INSERT INTO backupDeletion (tag) SELECT tag FROM backup WHERE folderID = ?
            ON CONFLICT DO NOTHING
            """,
          arguments: [folderID])
      }
      try db.execute(sql: "DELETE FROM backup WHERE folderID = ?", arguments: [folderID])
    }
  }

  func setBackupPausedByLicence(_ isPaused: Bool, folderID: Int64) throws {
    try database.write {
      try $0.execute(
        sql: "UPDATE backup SET pausedByLicence = ? WHERE folderID = ?",
        arguments: [isPaused, folderID])
    }
  }

  // MARK: Runs

  func backupRecord(folderID: Int64) throws -> BackupRecord? {
    try database.read { db in
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT * FROM backup WHERE folderID = ?", arguments: [folderID])
      else { return nil }
      return BackupRecord(
        folderID: row["folderID"],
        tag: row["tag"],
        history: try Self.history(row),
        lastRunAt: row["lastRunAt"],
        lastSuccessAt: row["lastSuccessAt"],
        lastSnapshotID: row["lastSnapshotID"],
        lastError: row["lastError"],
        failingSince: row["failingSince"],
        failedRunsInARow: row["failedRunsInARow"],
        lastForgetAt: row["lastForgetAt"],
        cloudOnlyCount: row["cloudOnlyCount"],
        skippedCount: try Int.fetchOne(
          db, sql: "SELECT count(*) FROM backupSkipped WHERE folderID = ?",
          arguments: [folderID]) ?? 0)
    }
  }

  /// A run's writes match the folder and the series it backs up: a run whose series is gone
  /// (Backup taken off, and maybe put on again with a new one) changes nothing.
  func recordBackupStarted(_ record: BackupRecord, at date: Date) throws {
    try database.write {
      try $0.execute(
        sql: "UPDATE backup SET lastRunAt = ? WHERE folderID = ? AND tag = ?",
        arguments: [date, record.folderID, record.tag])
    }
  }

  /// Records a backup that saved a snapshot, in one write: the folder's state, the files it
  /// couldn't read (in place of the last run's), the versions it saved, and History's row.
  func recordBackup(_ saved: SavedBackup, for record: BackupRecord, runID: Int64?, at date: Date)
    throws
  {
    let folderID = record.folderID
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE backup SET lastSuccessAt = ?, lastSnapshotID = ?, lastError = NULL,
            failingSince = NULL, failedRunsInARow = 0, cloudOnlyCount = ?
          WHERE folderID = ? AND tag = ?
          """,
        arguments: [saved.savedAt, saved.snapshotID, saved.cloudOnlyCount, folderID, record.tag])
      // Its series is gone: what it saved belongs to no folder that wears Backup now.
      guard db.changesCount > 0 else { return }
      try db.execute(sql: "DELETE FROM backupSkipped WHERE folderID = ?", arguments: [folderID])
      for skipped in saved.skipped {
        try db.execute(
          sql: "INSERT OR REPLACE INTO backupSkipped (folderID, path, reason) VALUES (?, ?, ?)",
          arguments: [folderID, skipped.path, skipped.reason])
      }
      for version in saved.versions {
        try db.execute(
          sql: """
            INSERT INTO backupVersion (folderID, path, snapshotID, savedAt, change, size)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            folderID, version.path, saved.snapshotID, saved.savedAt, version.change.rawValue,
            version.size,
          ])
      }
      guard let runID else { return }
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO backupRun
            (runID, folderID, snapshotID, filesNew, filesChanged, bytesAdded, skippedCount, endedAt)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          runID, folderID, saved.snapshotID, saved.filesNew, saved.filesChanged, saved.bytesAdded,
          saved.skipped.count, date,
        ])
    }
  }

  func recordBackupFailure(_ error: String, for record: BackupRecord, runID: Int64?, at date: Date)
    throws
  {
    let folderID = record.folderID
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE backup SET lastError = ?, failingSince = coalesce(failingSince, ?),
            failedRunsInARow = failedRunsInARow + 1
          WHERE folderID = ? AND tag = ?
          """,
        arguments: [error, date, folderID, record.tag])
      guard let runID, db.changesCount > 0 else { return }
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO backupRun (runID, folderID, error, endedAt) VALUES (?, ?, ?, ?)
          """,
        arguments: [runID, folderID, error, date])
    }
  }

  /// What a run recorded for History, by folder.
  public func backupRuns(runID: Int64) throws -> [BackupRunRecord] {
    try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM backupRun WHERE runID = ? ORDER BY folderID", arguments: [runID]
      ).map { row in
        BackupRunRecord(
          folderID: row["folderID"], snapshotID: row["snapshotID"], filesNew: row["filesNew"],
          filesChanged: row["filesChanged"], bytesAdded: row["bytesAdded"],
          skippedCount: row["skippedCount"], error: row["error"], endedAt: row["endedAt"])
      }
    }
  }

  // MARK: Forget

  /// After `forget`, with every snapshot left in the folder's series. A version saved in a
  /// snapshot that's gone (by this forget, or by one cut short before it) is still in the next
  /// kept snapshot, unless the file changed again before that one: so each kept snapshot holds the
  /// newest version of a file saved up to it, and the rest go from here as from the backup.
  func recordForget(folderID: Int64, kept: [ResticSnapshot], at date: Date) throws {
    let kept = kept.sorted { $0.time < $1.time }
    // Its own snapshot, or the next one kept after it. A version's date is stored to the
    // millisecond, so it's never compared with its own snapshot's.
    func holder(of version: StoredVersion) -> ResticSnapshot? {
      kept.first { $0.id == version.snapshotID } ?? kept.first { $0.time > version.savedAt }
    }
    try database.write { db in
      try db.execute(
        sql: "UPDATE backup SET lastForgetAt = ? WHERE folderID = ?", arguments: [date, folderID])
      let versions = try Row.fetchAll(
        db,
        sql: """
          SELECT id, path, snapshotID, savedAt FROM backupVersion WHERE folderID = ?
          ORDER BY savedAt, id
          """,
        arguments: [folderID]
      ).map(StoredVersion.init)
      let byFileAndHolder = Dictionary(grouping: versions) { [$0.path, holder(of: $0)?.id] }
      for group in byFileAndHolder.values {
        // Oldest first: the last is the newest saved up to the holder.
        guard let newest = group.last, let holder = holder(of: newest) else {
          try Self.deleteVersions(group, in: db)
          continue
        }
        try Self.deleteVersions(group.dropLast(), in: db)
        guard newest.snapshotID != holder.id else { continue }
        try db.execute(
          sql: "UPDATE backupVersion SET snapshotID = ?, savedAt = ? WHERE id = ?",
          arguments: [holder.id, holder.time, newest.id])
      }
    }
  }

  private static func deleteVersions(_ versions: some Sequence<StoredVersion>, in db: Database)
    throws
  {
    for version in versions {
      try db.execute(sql: "DELETE FROM backupVersion WHERE id = ?", arguments: [version.id])
    }
  }

  /// Every version of the folder's files the backup holds, oldest first.
  public func backupVersions(folderID: Int64) throws -> [BackupVersion] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM backupVersion WHERE folderID = ? ORDER BY savedAt, path",
        arguments: [folderID]
      ).map { row in
        let change: String = row["change"]
        guard let change = BackupVersion.Change(rawValue: change) else {
          throw DatabaseError(message: "Unknown change \(change)")
        }
        return BackupVersion(
          path: row["path"], snapshotID: row["snapshotID"], savedAt: row["savedAt"],
          change: change, size: row["size"])
      }
    }
  }

  // MARK: Left out and skipped

  func backupLeftOut(folderID: Int64) throws -> [LeaveOut] {
    try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT kind, value FROM backupLeftOut WHERE folderID = ? ORDER BY kind, value",
        arguments: [folderID]
      ).map { row in
        let kind: String = row["kind"]
        let value: String = row["value"]
        switch kind {
        case "path": return .path(value)
        case "name": return .name(value)
        default: throw DatabaseError(message: "Unknown leave-out \(kind)")
        }
      }
    }
  }

  /// Leaves `item` out of the folder's next backups, and stops counting what it covers as
  /// skipped: the user chose to leave it out.
  func leaveOut(_ item: LeaveOut, folderID: Int64) throws {
    let (kind, value) = Self.columns(item)
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backupLeftOut (folderID, kind, value)
          SELECT folderID, ?, ? FROM backup WHERE folderID = ?
          ON CONFLICT DO NOTHING
          """,
        arguments: [kind, value, folderID])
      let skipped = try String.fetchAll(
        db, sql: "SELECT path FROM backupSkipped WHERE folderID = ?", arguments: [folderID])
      for path in skipped where item.covers(path) {
        try db.execute(
          sql: "DELETE FROM backupSkipped WHERE folderID = ? AND path = ?",
          arguments: [folderID, path])
      }
    }
  }

  func bringBack(_ item: LeaveOut, folderID: Int64) throws {
    let (kind, value) = Self.columns(item)
    try database.write {
      try $0.execute(
        sql: "DELETE FROM backupLeftOut WHERE folderID = ? AND kind = ? AND value = ?",
        arguments: [folderID, kind, value])
    }
  }

  func backupSkipped(folderID: Int64) throws -> [SkippedFile] {
    try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT path, reason FROM backupSkipped WHERE folderID = ? ORDER BY path",
        arguments: [folderID]
      ).map { SkippedFile(path: $0["path"], reason: $0["reason"]) }
    }
  }

  // MARK: The account and the repository

  func backupAccount() throws -> BackupAccount? {
    try database.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM backupAccount").map { row in
        let custody: String = row["keyCustody"]
        guard let custody = KeyCustody(rawValue: custody) else {
          throw DatabaseError(message: "Unknown key custody \(custody)")
        }
        return BackupAccount(
          host: row["host"], keyCustody: custody, lastPrunedAt: row["lastPrunedAt"],
          createdAt: row["createdAt"])
      }
    }
  }

  func createBackupAccount(host: String, now: Date) throws {
    try database.write {
      try $0.execute(
        sql: """
          INSERT INTO backupAccount (id, host, keyCustody, createdAt) VALUES (1, ?, ?, ?)
          ON CONFLICT DO NOTHING
          """,
        arguments: [host, KeyCustody.besideBackup.rawValue, now])
    }
  }

  func setKeyCustody(_ custody: KeyCustody) throws {
    try database.write {
      try $0.execute(
        sql: "UPDATE backupAccount SET keyCustody = ?", arguments: [custody.rawValue])
    }
  }

  func recordPrune(at date: Date) throws {
    try database.write {
      try $0.execute(sql: "UPDATE backupAccount SET lastPrunedAt = ?", arguments: [date])
    }
  }

  func pendingBackupDeletions() throws -> [String] {
    try database.read {
      try String.fetchAll($0, sql: "SELECT tag FROM backupDeletion ORDER BY tag")
    }
  }

  func finishBackupDeletions(_ tags: [String]) throws {
    try database.write { db in
      for tag in tags {
        try db.execute(sql: "DELETE FROM backupDeletion WHERE tag = ?", arguments: [tag])
      }
    }
  }

  // MARK: Rows

  private static func backupWear(_ row: Row) throws -> Wear<BackupSettings> {
    Wear(
      folderID: row["folderID"],
      settings: BackupSettings(history: try history(row)),
      isPausedByLicence: row["pausedByLicence"],
      lastRunAt: row["lastRunAt"])
  }

  private static func history(_ row: Row) throws -> BackupHistory {
    let history: String = row["history"]
    guard let history = BackupHistory(rawValue: history) else {
      throw DatabaseError(message: "Unknown history \(history)")
    }
    return history
  }

  private static func columns(_ item: LeaveOut) -> (kind: String, value: String) {
    switch item {
    case .path(let path): ("path", path)
    case .name(let name): ("name", name)
    }
  }
}

/// A Backup folder's row, as a run reads and writes it.
struct BackupRecord: Sendable, Equatable {
  var folderID: Int64
  var tag: String
  var history: BackupHistory
  var lastRunAt: Date
  var lastSuccessAt: Date?
  var lastSnapshotID: String?
  var lastError: String?
  var failingSince: Date?
  var failedRunsInARow: Int
  var lastForgetAt: Date?
  var cloudOnlyCount: Int
  var skippedCount: Int

  var resticTag: String { Self.resticTag(tag) }

  /// restic's tag for a folder's series.
  static func resticTag(_ tag: String) -> String { "folder=\(tag)" }
}

/// A `backupVersion` row, as a forget sorts them.
struct StoredVersion {
  var id: Int64
  var path: String
  var snapshotID: String
  var savedAt: Date

  init(row: Row) {
    id = row["id"]
    path = row["path"]
    snapshotID = row["snapshotID"]
    savedAt = row["savedAt"]
  }
}

/// What a backup that saved a snapshot records.
struct SavedBackup: Sendable {
  var snapshotID: String
  var savedAt: Date
  var filesNew: Int
  var filesChanged: Int
  var bytesAdded: Int64
  var skipped: [SkippedFile]
  var versions: [SavedVersion]
  var cloudOnlyCount: Int
}

struct SavedVersion: Sendable, Equatable {
  var path: String
  var change: BackupVersion.Change
  var size: Int64?
}

/// The Mac's one repository.
struct BackupAccount: Sendable, Equatable {
  var host: String
  var keyCustody: KeyCustody
  var lastPrunedAt: Date?
  var createdAt: Date
}

/// Who holds the key that opens the Mac's repository.
public enum KeyCustody: String, Sendable, Equatable {
  /// In the repository's folder as `password.txt`, and in the login Keychain: signing in to the
  /// account that holds the backup is enough to restore it, on any Mac.
  case besideBackup
  /// Private Backup: the user's recovery key, and the login Keychain. A lost key with no Mac
  /// that still holds it is a lost backup.
  case `private`
}

/// A file the last backup couldn't read, so isn't in it.
public struct SkippedFile: Sendable, Equatable {
  /// Inside the folder.
  public var path: String
  public var reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }
}

/// A version of a file the backup holds: what one snapshot saved of it.
public struct BackupVersion: Sendable, Equatable {
  public enum Change: String, Sendable {
    case added, changed, removed
  }

  /// Inside the folder.
  public var path: String
  public var snapshotID: String
  public var savedAt: Date
  public var change: Change
  /// Its size when saved; nil for a removal.
  public var size: Int64?
}

/// What one run did to one folder, as History shows it.
public struct BackupRunRecord: Sendable, Equatable {
  public var folderID: Int64
  /// Nil when it failed.
  public var snapshotID: String?
  public var filesNew: Int
  public var filesChanged: Int
  public var bytesAdded: Int64
  public var skippedCount: Int
  public var error: String?
  public var endedAt: Date
}

extension LeaveOut {
  /// Whether it leaves out the file at `path` inside the folder.
  func covers(_ path: String) -> Bool {
    switch self {
    case .path(let leftOut): path == leftOut || path.hasPrefix(leftOut + "/")
    case .name(let name): path.split(separator: "/").contains { $0 == name }
    }
  }
}
