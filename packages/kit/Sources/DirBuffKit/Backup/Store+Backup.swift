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

  /// The day each cause last had its notification (once per cause per day), kept so a
  /// relaunch doesn't send it again. Registered after the open runs'.
  static func registerBackupNotificationMigrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("backup notifications") { db in
      try db.create(table: "backupNotified") { t in
        t.primaryKey("cause", .text)
        t.column("day", .text).notNull()
      }
    }
  }

  /// Registered after the bridge's: migrations run in the order they're registered.
  static func registerBackupOnDriveMigrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("backup on drive") { db in
      // One row: where the Macs' backups are in Drive, and which is this Mac's, by ID, kept as
      // soon as each is found or made.
      try db.create(table: "backupDrive") { t in
        t.primaryKey("id", .integer).check { $0 == 1 }
        t.column("backupsFolderID", .text)
        t.column("repositoryFolderID", .text)
      }
      try db.alter(table: "backupAccount") { t in
        // `backupDrive` holds them, from before the repository exists.
        t.drop(column: "driveFolderID")
        t.drop(column: "repositoryDriveID")
        // The repository opens with no password, or with the one the Keychain keeps: nothing
        // is kept beside the backup any more.
        t.drop(column: "keyCustody")
        // The last weekly check that ran to its end, and what it found missing (nil: nothing).
        t.add(column: "lastCheckAt", .datetime)
        t.add(column: "lastCheckProblem", .text)
        // The time of the snapshot the last check restored a file from, so the next takes the
        // one after it.
        t.add(column: "lastSampledAt", .datetime)
        // A change of password under way: until it's finished, keys other than the Keychain's
        // may still open the repository.
        t.add(column: "isKeyChangePending", .boolean).notNull().defaults(to: false)
        // This Mac took over another's repository and its password is still to move from the
        // Keychain's staging slot.
        t.add(column: "isAdoptionPending", .boolean).notNull().defaults(to: false)
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

  /// Puts Backup on the folder continuing the series `tag` of a backup it was restored from, so
  /// what it holds is found in the repository and doesn't upload again. A folder that wears
  /// Backup already moves to that series; its versions were of the old one.
  func continueBackupSeries(_ series: [Int64: String], settings: BackupSettings, now: Date)
    throws
  {
    try database.write { db in
      try Self.continueBackupSeries(series, settings: settings, now: now, in: db)
    }
  }

  private static func continueBackupSeries(
    _ series: [Int64: String], settings: BackupSettings, now: Date, in db: Database
  ) throws {
    for (folderID, tag) in series {
      try db.execute(
        sql: """
          INSERT INTO backup (folderID, tag, history, lastRunAt) VALUES (?, ?, ?, ?)
          ON CONFLICT (folderID) DO UPDATE SET tag = excluded.tag, pausedByLicence = 0,
            lastSnapshotID = NULL, lastForgetAt = NULL
          """,
        arguments: [folderID, tag, settings.history.rawValue, now])
      try db.execute(sql: "DELETE FROM backupVersion WHERE folderID = ?", arguments: [folderID])
    }
  }

  /// The first of `series` (folder → series) that two folders would share, counting the folders
  /// that keep the series they have.
  func sharedBackupSeries(_ series: [Int64: String]) throws -> String? {
    try database.read { db in
      let kept = try Row.fetchAll(db, sql: "SELECT folderID, tag FROM backup")
        .reduce(into: [Int64: String]()) { $0[$1["folderID"]] = $1["tag"] }
      let all = kept.merging(series) { $1 }.values.sorted()
      return zip(all, all.dropFirst()).first { $0 == $1 }?.0
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

  /// Opens a History run for a backup of the folder. Its `backupRun` row exists from the start,
  /// with no outcome: the attempt is running until the backup records one, or `endRun` or the
  /// next launch (`closeInterruptedRuns`) settles it.
  public func beginBackupRun(folderID: Int64, at date: Date) throws -> Int64 {
    try database.write { db in
      let runID = try Self.openRun(of: .backup, at: date, in: db)
      try db.execute(
        sql: "INSERT INTO backupRun (runID, folderID, endedAt) VALUES (?, ?, ?)",
        arguments: [runID, folderID, date])
      return runID
    }
  }

  /// The folder's latest attempts to back up, newest first: those with a History run.
  public func backupAttempts(folderID: Int64, limit: Int) throws -> [BackupAttempt] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT run.startedAt, backupRun.* FROM backupRun JOIN run ON run.id = backupRun.runID
          WHERE backupRun.folderID = ? ORDER BY run.startedAt DESC, run.id DESC LIMIT ?
          """,
        arguments: [folderID, limit]
      ).map { row in
        BackupAttempt(
          startedAt: row["startedAt"], endedAt: row["endedAt"], snapshotID: row["snapshotID"],
          filesNew: row["filesNew"], filesChanged: row["filesChanged"],
          bytesAdded: row["bytesAdded"], skippedCount: row["skippedCount"], error: row["error"])
      }
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
      ).map(Self.backupVersion)
    }
  }

  /// The versions of one file, oldest first.
  func backupVersions(folderID: Int64, path: String) throws -> [BackupVersion] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM backupVersion WHERE folderID = ? AND path = ? ORDER BY savedAt, id",
        arguments: [folderID, path]
      ).map(Self.backupVersion)
    }
  }

  private static func backupVersion(_ row: Row) throws -> BackupVersion {
    let change: String = row["change"]
    guard let change = BackupVersion.Change(rawValue: change) else {
      throw DatabaseError(message: "Unknown change \(change)")
    }
    return BackupVersion(
      path: row["path"], snapshotID: row["snapshotID"], savedAt: row["savedAt"],
      change: change, size: row["size"])
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
        BackupAccount(
          host: row["host"], lastPrunedAt: row["lastPrunedAt"],
          createdAt: row["createdAt"], lastCheckAt: row["lastCheckAt"],
          lastCheckProblem: row["lastCheckProblem"], lastSampledAt: row["lastSampledAt"],
          isKeyChangePending: row["isKeyChangePending"], isAdoptionPending: row["isAdoptionPending"]
        )
      }
    }
  }

  func createBackupAccount(host: String, now: Date) throws {
    try database.write {
      try $0.execute(
        sql: """
          INSERT INTO backupAccount (id, host, createdAt) VALUES (1, ?, ?)
          ON CONFLICT DO NOTHING
          """,
        arguments: [host, now])
    }
  }

  func recordPrune(at date: Date) throws {
    try database.write {
      try $0.execute(sql: "UPDATE backupAccount SET lastPrunedAt = ?", arguments: [date])
    }
  }

  /// This Mac takes over another's repository, with its snapshots' host. What
  /// this Mac recorded of the repository it leaves (each folder's last snapshot, versions,
  /// deletions, prunes and checks) was of that one, so it goes.
  ///
  /// In one write: the account, the repository it points at (`repository`, the storage's ID for
  /// it), each folder in `series` on the series it continues, and the adoption marked pending
  /// until the password moves into place in the Keychain.
  func adoptBackupRepository(
    host: String, repository: String, series: [Int64: String], settings: BackupSettings,
    now: Date
  ) throws {
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO backupAccount (id, host, createdAt, isAdoptionPending) VALUES (1, ?, ?, 1)
          ON CONFLICT (id) DO UPDATE SET host = excluded.host, createdAt = excluded.createdAt,
            lastPrunedAt = NULL, lastCheckAt = NULL, lastCheckProblem = NULL,
            lastSampledAt = NULL, isKeyChangePending = 0, isAdoptionPending = 1
          """,
        arguments: [host, now])
      try db.execute(
        sql: """
          INSERT INTO backupDrive (id, repositoryFolderID) VALUES (1, ?)
          ON CONFLICT (id) DO UPDATE SET repositoryFolderID = excluded.repositoryFolderID
          """,
        arguments: [repository])
      try db.execute(sql: "UPDATE backup SET lastSnapshotID = NULL, lastForgetAt = NULL")
      try db.execute(sql: "DELETE FROM backupVersion")
      try db.execute(sql: "DELETE FROM backupDeletion")
      try Self.continueBackupSeries(series, settings: settings, now: now, in: db)
    }
  }

  func setKeyChangePending(_ isPending: Bool) throws {
    try database.write {
      try $0.execute(
        sql: "UPDATE backupAccount SET isKeyChangePending = ?", arguments: [isPending])
    }
  }

  func finishAdoption() throws {
    try database.write {
      try $0.execute(sql: "UPDATE backupAccount SET isAdoptionPending = 0")
    }
  }

  /// A weekly check that ran to its end, and the snapshot it restored a file from, if any.
  func recordCheck(_ check: BackupCheck, sampledAt: Date?) throws {
    try database.write {
      try $0.execute(
        sql: """
          UPDATE backupAccount SET lastCheckAt = ?, lastCheckProblem = ?,
            lastSampledAt = coalesce(?, lastSampledAt)
          """,
        arguments: [check.checkedAt, check.problem, sampledAt])
    }
  }

  // MARK: Notifications

  /// Whether the notification for `cause` went out on `now`'s day.
  public func wasNotified(cause: String, on now: Date, calendar: Calendar) throws -> Bool {
    try database.read { db in
      try String.fetchOne(
        db, sql: "SELECT day FROM backupNotified WHERE cause = ?", arguments: [cause])
        == Self.dayKey(now, calendar: calendar)
    }
  }

  /// Records that the notification for `cause` went out on `now`'s day, and forgets the days
  /// before it.
  public func recordNotified(cause: String, on now: Date, calendar: Calendar) throws {
    let day = Self.dayKey(now, calendar: calendar)
    try database.write { db in
      try db.execute(sql: "DELETE FROM backupNotified WHERE day < ?", arguments: [day])
      try db.execute(
        sql: """
          INSERT INTO backupNotified (cause, day) VALUES (?, ?)
          ON CONFLICT (cause) DO UPDATE SET day = excluded.day
          """,
        arguments: [cause, day])
    }
  }

  /// "2026-11-11": sorts as dates do.
  static func dayKey(_ date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  // MARK: Drive

  /// `DirBuff Backup` and this Mac's repository in it, each once found or made.
  func backupDriveFolders() throws -> (backups: DriveFileID?, repository: DriveFileID?) {
    try database.read { db in
      let row = try Row.fetchOne(db, sql: "SELECT * FROM backupDrive")
      let backups: String? = row?["backupsFolderID"]
      let repository: String? = row?["repositoryFolderID"]
      return (backups.map { DriveFileID($0) }, repository.map { DriveFileID($0) })
    }
  }

  func saveBackupDriveFolder(_ id: DriveFileID) throws {
    try database.write {
      try $0.execute(
        sql: """
          INSERT INTO backupDrive (id, backupsFolderID) VALUES (1, ?)
          ON CONFLICT (id) DO UPDATE SET backupsFolderID = excluded.backupsFolderID
          """,
        arguments: [id.rawValue])
    }
  }

  func saveBackupDriveRepository(_ id: DriveFileID) throws {
    try database.write {
      try $0.execute(
        sql: """
          INSERT INTO backupDrive (id, repositoryFolderID) VALUES (1, ?)
          ON CONFLICT (id) DO UPDATE SET repositoryFolderID = excluded.repositoryFolderID
          """,
        arguments: [id.rawValue])
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

  /// The series a restic tag names, if it names one.
  static func series(_ resticTag: String) -> String? {
    resticTag.hasPrefix("folder=") ? String(resticTag.dropFirst("folder=".count)) : nil
  }
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
  var lastPrunedAt: Date?
  var createdAt: Date
  var lastCheckAt: Date?
  var lastCheckProblem: String?
  var lastSampledAt: Date?
  var isKeyChangePending: Bool
  var isAdoptionPending: Bool
}

/// One attempt to back a folder up, as the status file and History tell it.
public struct BackupAttempt: Sendable, Equatable {
  public enum Outcome: String, Sendable, Equatable, Codable {
    /// No outcome yet.
    case running
    /// A snapshot was saved, with or without files it couldn't read.
    case saved
    case failed
  }

  public var startedAt: Date
  /// When the outcome was recorded; nil while it is running.
  public var endedAt: Date?
  public var snapshotID: String?
  public var filesNew: Int
  public var filesChanged: Int
  public var bytesAdded: Int64
  public var skippedCount: Int
  public var error: String?

  public var outcome: Outcome {
    if error != nil { return .failed }
    return snapshotID == nil ? .running : .saved
  }

  public init(
    startedAt: Date, endedAt: Date?, snapshotID: String?, filesNew: Int, filesChanged: Int,
    bytesAdded: Int64, skippedCount: Int, error: String?
  ) {
    self.startedAt = startedAt
    // The row's time before an outcome is only the start's placeholder.
    self.endedAt = snapshotID != nil || error != nil ? endedAt : nil
    self.snapshotID = snapshotID
    self.filesNew = filesNew
    self.filesChanged = filesChanged
    self.bytesAdded = bytesAdded
    self.skippedCount = skippedCount
    self.error = error
  }
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

  public init(path: String, snapshotID: String, savedAt: Date, change: Change, size: Int64?) {
    self.path = path
    self.snapshotID = snapshotID
    self.savedAt = savedAt
    self.change = change
    self.size = size
  }
}

/// What one run did to one folder, as History shows it.
public struct BackupRunRecord: Sendable, Equatable {
  /// The outcome of a backup a quit cut short.
  public static let interruptedMessage = "DirBuff quit before this backup finished"

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
