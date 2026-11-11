import DirBuffCore
import Foundation
import GRDB

/// A folder the user added to DirBuff: the registry's record of where it is. What it wears is in
/// each buff's own table.
public struct Folder: Sendable, Equatable {
  public internal(set) var id: Int64?
  /// Finds the folder again after it is renamed or moved. Not security-scoped: the app is not
  /// sandboxed.
  public internal(set) var bookmark: Data
  /// Where the folder was last seen.
  public internal(set) var path: String
  /// Since when macOS has refused DirBuff access to the folder; nil while it can read it.
  public internal(set) var accessLostAt: Date?
  /// Since when the folder has been missing: deleted, moved to another disk, or moved to the Bin.
  public internal(set) var missingSince: Date?
  public internal(set) var createdAt: Date

  public init(
    id: Int64? = nil,
    bookmark: Data,
    path: String,
    accessLostAt: Date? = nil,
    missingSince: Date? = nil,
    createdAt: Date
  ) {
    self.id = id
    self.bookmark = bookmark
    self.path = path
    self.accessLostAt = accessLostAt
    self.missingSince = missingSince
    self.createdAt = createdAt
  }
}

/// One item a run disposed of.
public struct JournalEntry: Sendable, Equatable, Codable {
  public internal(set) var id: Int64?
  /// The clean-up that removed it; nil for an entry from before runs were recorded.
  public var runID: Int64?
  public var folderID: Int64
  public var disposal: Disposal
  /// The item's name in its folder. Items are top-level, so this and the folder's bookmark find
  /// where it goes back to, even after the folder is renamed.
  public var name: String
  /// Where the item is in the Bin; nil once deleted. macOS renames an item on a name clash, so
  /// this is the path `trashItem` returned, never a guess.
  public var binnedPath: String?
  public var size: Int64
  /// The rule that chose the item. 0.1.x could combine rules, so an older entry may name several.
  public var reasons: Set<Rule>
  public var performedAt: Date
  public var undoneAt: Date?

  public init(
    id: Int64? = nil,
    runID: Int64? = nil,
    folderID: Int64,
    disposal: Disposal,
    name: String,
    binnedPath: String? = nil,
    size: Int64,
    reasons: Set<Rule>,
    performedAt: Date,
    undoneAt: Date? = nil
  ) {
    self.id = id
    self.runID = runID
    self.folderID = folderID
    self.disposal = disposal
    self.name = name
    self.binnedPath = binnedPath
    self.size = size
    self.reasons = reasons
    self.performedAt = performedAt
    self.undoneAt = undoneAt
  }
}

/// DirBuff's one database: the folders, the journal of what runs did, and the
/// licence.
public struct Store: Sendable {
  let database: DatabaseQueue

  public init(path: String) throws {
    try self.init(DatabaseQueue(path: path))
  }

  public static func inMemory() throws -> Store {
    try Store(DatabaseQueue())
  }

  init(_ database: DatabaseQueue) throws {
    self.database = database
    try Self.migrator.migrate(database)
  }

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("temporary folders and journal") { db in
      try db.create(table: "folder") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("bookmark", .blob).notNull()
        t.column("path", .text).notNull()
        t.column("maxAgeDays", .integer)
        t.column("sizeLimit", .integer)
        t.column("automatic", .boolean).notNull()
        t.column("emptyOnRestart", .boolean).notNull()
        t.column("disposal", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("lastRunAt", .datetime).notNull()
      }
      try db.create(table: "journalEntry") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("folderID", .integer).notNull().indexed()
          .references("folder", onDelete: .cascade)
        t.column("disposal", .text).notNull()
        t.column("name", .text).notNull()
        t.column("binnedPath", .text)
        t.column("size", .integer).notNull()
        t.column("reasons", .jsonText).notNull()
        t.column("performedAt", .datetime).notNull().indexed()
        t.column("undoneAt", .datetime)
      }
    }
    // The trial starts when this migration runs: the first launch of a build that has licensing.
    migrator.registerMigration("licence") { db in
      try db.alter(table: "folder") { t in
        t.add(column: "turnedOffByLicence", .boolean).notNull().defaults(to: false)
      }
      try db.create(table: "licence") { t in
        t.column("trialStartedAt", .datetime).notNull()
        t.column("key", .text)
        t.column("activationID", .text)
        t.column("lastCheckedAt", .datetime)
        t.column("hasEnded", .boolean).notNull()
      }
      try db.execute(
        sql: "INSERT INTO licence (trialStartedAt, hasEnded) VALUES (?, 0)", arguments: [Date()])
    }
    // Temporary moves from a Finder tag into the database. Folders that exist now still owe the
    // tag's removal (`Engine` takes it off the first time it reaches one), so they are listed here.
    migrator.registerMigration("temporary in the database") { db in
      try db.alter(table: "folder") { t in
        t.add(column: "wearsTemporary", .boolean).notNull().defaults(to: false)
        t.add(column: "takenOffAt", .datetime)
      }
      try db.create(table: "legacyTagPending") { t in
        t.primaryKey("folderID", .integer).references("folder", onDelete: .cascade)
      }
      try db.execute(sql: "INSERT INTO legacyTagPending (folderID) SELECT id FROM folder")
    }
    // One rule where 0.1.x could combine several: the first set of Age, Size, Empty on restart and
    // Automatic (which acted only when deleting). A folder with no rule set stays plain, whether
    // its tag is still pending (`hadRule`) or a dev build already took it off, and can't come
    // back through Put Back or a licence's Turn All Back On with the rule it would gain.
    migrator.registerMigration("one rule") { db in
      let hasRule = """
        (maxAgeDays IS NOT NULL OR sizeLimit IS NOT NULL OR emptyOnRestart
          OR (automatic AND disposal = 'delete'))
        """
      try db.alter(table: "folder") { t in
        t.add(column: "rule", .text).notNull().defaults(to: Rule.age.rawValue)
      }
      try db.alter(table: "legacyTagPending") { t in
        t.add(column: "hadRule", .boolean).notNull().defaults(to: true)
      }
      try db.execute(
        sql: """
          UPDATE legacyTagPending SET hadRule = (
            SELECT \(hasRule) FROM folder WHERE folder.id = legacyTagPending.folderID);
          UPDATE folder SET wearsTemporary = 0, takenOffAt = NULL, turnedOffByLicence = 0
            WHERE NOT \(hasRule);
          UPDATE folder SET rule = CASE
            WHEN maxAgeDays IS NOT NULL THEN 'age'
            WHEN sizeLimit IS NOT NULL THEN 'size'
            WHEN emptyOnRestart THEN 'emptyOnRestart'
            WHEN automatic AND disposal = 'delete' THEN 'automatic'
            ELSE 'age'
          END;
          UPDATE folder SET maxAgeDays = coalesce(maxAgeDays, ?), sizeLimit = coalesce(sizeLimit, ?);
          """,
        arguments: [TemporarySettings.defaultMaxAgeDays, TemporarySettings.defaultSizeLimit])
      try db.alter(table: "folder") { t in
        t.drop(column: "automatic")
        t.drop(column: "emptyOnRestart")
      }
    }
    migrator.registerMigration("access lost") { db in
      try db.alter(table: "folder") { t in t.add(column: "accessLostAt", .datetime) }
    }
    // A run is one clean-up across every folder, which History lists.
    migrator.registerMigration("runs and missing folders") { db in
      try db.create(table: "run") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("startedAt", .datetime).notNull().indexed()
      }
      try db.alter(table: "journalEntry") { t in
        t.add(column: "runID", .integer).references("run", onDelete: .cascade)
      }
      try db.create(index: "journalEntry_on_runID", on: "journalEntry", columns: ["runID"])
      try db.alter(table: "folder") { t in t.add(column: "missingSince", .datetime) }
      // Taking a buff off is final: its settings are forgotten, and there's nothing to put back.
      try db.execute(
        sql: """
          UPDATE folder SET rule = 'age', maxAgeDays = ?, sizeLimit = ?, disposal = 'bin'
            WHERE NOT wearsTemporary AND NOT turnedOffByLicence AND takenOffAt IS NOT NULL
          """,
        arguments: [TemporarySettings.defaultMaxAgeDays, TemporarySettings.defaultSizeLimit])
      try db.alter(table: "folder") { t in t.drop(column: "takenOffAt") }
    }
    registerHistoryMigrations(&migrator)
    // Each buff keeps its own table, settings as columns, and a folder wears the buff while the
    // table has its row; the folder table is left as the registry. A folder still owing its
    // legacy tag's removal wears nothing until the tag is read, so the settings the tag would put
    // back wait with it. Every run is one buff's.
    migrator.registerMigration("buff tables") { db in
      let defaults: StatementArguments = [
        TemporarySettings.defaultMaxAgeDays, TemporarySettings.defaultSizeLimit,
      ]
      try db.create(table: "temporary") { t in
        t.primaryKey("folderID", .integer).references("folder", onDelete: .cascade)
        t.column("rule", .text).notNull()
        t.column("maxAgeDays", .integer).notNull()
        t.column("sizeLimit", .integer).notNull()
        t.column("disposal", .text).notNull()
        t.column("pausedByLicence", .boolean).notNull().defaults(to: false)
        t.column("lastRunAt", .datetime).notNull()
      }
      try db.execute(
        sql: """
          INSERT INTO temporary
            (folderID, rule, maxAgeDays, sizeLimit, disposal, pausedByLicence, lastRunAt)
          SELECT id, rule, coalesce(maxAgeDays, ?1), coalesce(sizeLimit, ?2), disposal,
            turnedOffByLicence, lastRunAt
          FROM folder WHERE wearsTemporary OR turnedOffByLicence
          """, arguments: defaults)
      try db.alter(table: "legacyTagPending") { t in
        t.add(column: "rule", .text)
        t.add(column: "maxAgeDays", .integer)
        t.add(column: "sizeLimit", .integer)
        t.add(column: "disposal", .text)
        t.add(column: "lastRunAt", .datetime)
      }
      try db.execute(
        sql: """
          UPDATE legacyTagPending SET (rule, maxAgeDays, sizeLimit, disposal, lastRunAt) = (
            SELECT rule, coalesce(maxAgeDays, ?1), coalesce(sizeLimit, ?2), disposal, lastRunAt
            FROM folder WHERE folder.id = legacyTagPending.folderID)
          """, arguments: defaults)
      try db.alter(table: "folder") { t in
        for column in [
          "rule", "maxAgeDays", "sizeLimit", "disposal", "wearsTemporary", "turnedOffByLicence",
          "lastRunAt",
        ] {
          t.drop(column: column)
        }
      }
      try db.alter(table: "run") { t in
        t.add(column: "buff", .text).notNull().defaults(to: Buff.temporary.rawValue)
      }
    }
    registerBackupMigrations(&migrator)
    registerDriveBridgeMigrations(&migrator)
    registerBackupOnDriveMigrations(&migrator)
    registerOpenRunMigrations(&migrator)
    registerBackupNotificationMigrations(&migrator)
    registerBackupAccountMigrations(&migrator)
    registerBackupOwnerMigrations(&migrator)
    return migrator
  }

  public func folders() throws -> [Folder] {
    try database.read { try Folder.order(Column("createdAt")).fetchAll($0) }
  }

  public func folder(id: Int64) throws -> Folder? {
    try database.read { try Folder.fetchOne($0, key: id) }
  }

  public func folder(path: String) throws -> Folder? {
    try database.read { try Folder.filter(Column("path") == path).fetchOne($0) }
  }

  func insert(_ folder: Folder) throws -> Folder {
    try database.write { try folder.inserted($0) }
  }

  public func save(_ folder: Folder) throws {
    try database.write { try folder.update($0) }
  }

  func deleteFolder(id: Int64) throws {
    _ = try database.write { try Folder.deleteOne($0, key: id) }
  }

  func hasLegacyTag(folderID: Int64) throws -> Bool {
    try database.read {
      try Bool.fetchOne(
        $0, sql: "SELECT EXISTS (SELECT 1 FROM legacyTagPending WHERE folderID = ?)",
        arguments: [folderID]) ?? false
    }
  }

  /// Records whether DirBuff could read the folder: the first refusal's time while macOS refuses
  /// it, cleared once it can read the folder again.
  public func recordAccess(folderID: Int64, isLost: Bool, at date: Date) throws {
    try database.write {
      try $0.execute(
        sql: """
          UPDATE folder SET accessLostAt = CASE WHEN ? THEN coalesce(accessLostAt, ?) END
          WHERE id = ?
          """,
        arguments: [isLost, date, folderID])
    }
  }

  /// Records whether the folder is missing: since when while it is, cleared once it's found.
  public func recordMissing(folderID: Int64, isMissing: Bool, at date: Date) throws {
    try database.write {
      try $0.execute(
        sql: """
          UPDATE folder SET missingSince = CASE WHEN ? THEN coalesce(missingSince, ?) END
          WHERE id = ?
          """,
        arguments: [isMissing, date, folderID])
    }
  }

  /// Opens a run: one buff's run across every folder that wears it, as History lists it. Returns
  /// its id for the buff's runs to record under. The run stays open until `endRun`, or until the
  /// next launch closes it (`closeInterruptedRuns`), and no other run's begin drops it. Runs left
  /// empty (a removed folder's only run) are dropped first.
  public func beginRun(of buff: Buff, at date: Date) throws -> Int64 {
    try database.write { try Self.openRun(of: buff, at: date, in: $0) }
  }

  static func openRun(of buff: Buff, at date: Date, in db: Database) throws -> Int64 {
    try db.execute(sql: "DELETE FROM run WHERE \(Self.isEmptyRun)")
    try db.execute(
      sql: "INSERT INTO run (buff, startedAt, isOpen) VALUES (?, ?, 1)",
      arguments: [buff.rawValue, date])
    return db.lastInsertedRowID
  }

  /// Closes a run that has finished, and drops it if it did nothing, so History lists only runs
  /// that did something. A backup that never reached an outcome (its folder came off Backup
  /// meanwhile) did nothing.
  public func endRun(id: Int64) throws {
    try database.write { db in
      try db.execute(
        sql: "DELETE FROM backupRun WHERE runID = ? AND snapshotID IS NULL AND error IS NULL",
        arguments: [id])
      try db.execute(sql: "UPDATE run SET isOpen = 0 WHERE id = ?", arguments: [id])
      try db.execute(sql: "DELETE FROM run WHERE id = ? AND \(Self.isEmptyRun)", arguments: [id])
    }
  }

  /// Closes the runs a quit cut short, at launch, when no run of this process can be open. A
  /// backup that hadn't reached an outcome says so as its outcome; a run that did nothing goes.
  public func closeInterruptedRuns(at date: Date) throws {
    try database.write { db in
      try db.execute(
        sql: """
          UPDATE backupRun SET error = ?, endedAt = ?
          WHERE snapshotID IS NULL AND error IS NULL
            AND runID IN (SELECT id FROM run WHERE isOpen)
          """,
        arguments: [BackupRunRecord.interruptedMessage, date])
      try db.execute(sql: "UPDATE run SET isOpen = 0 WHERE isOpen")
      try db.execute(sql: "DELETE FROM run WHERE \(Self.isEmptyRun)")
    }
  }

  /// SQL true for a `run` row nothing was recorded under: no file a clean-up removed, no folder a
  /// backup ran on, and no run still going.
  static let isEmptyRun = """
    NOT run.isOpen
      AND NOT EXISTS (SELECT 1 FROM journalEntry WHERE runID = run.id)
      AND NOT EXISTS (SELECT 1 FROM backupRun WHERE runID = run.id)
    """

  public func licence() throws -> LicenceRecord {
    try database.read { db in
      guard let row = try Row.fetchOne(db, sql: "SELECT * FROM licence") else {
        throw DatabaseError(message: "The licence row is missing")
      }
      return LicenceRecord(
        trialStartedAt: row["trialStartedAt"],
        key: row["key"],
        activationID: row["activationID"],
        lastCheckedAt: row["lastCheckedAt"],
        hasEnded: row["hasEnded"]
      )
    }
  }

  public func save(_ licence: LicenceRecord) throws {
    try database.write {
      try $0.execute(
        sql: """
          UPDATE licence SET trialStartedAt = ?, key = ?, activationID = ?, lastCheckedAt = ?,
            hasEnded = ?
          """,
        arguments: [
          licence.trialStartedAt, licence.key, licence.activationID, licence.lastCheckedAt,
          licence.hasEnded,
        ])
    }
  }

  /// Newest first.
  public func journal(folderID: Int64) throws -> [JournalEntry] {
    try database.read {
      try JournalEntry.filter(Column("folderID") == folderID)
        .order(Column("performedAt").desc, Column("id").desc)
        .fetchAll($0)
    }
  }

  /// Every folder's journal since `date`, newest first.
  public func journal(since date: Date) throws -> [JournalEntry] {
    try database.read {
      try JournalEntry.filter(Column("performedAt") >= date)
        .order(Column("performedAt").desc, Column("id").desc)
        .fetchAll($0)
    }
  }

  public func journalEntry(id: Int64) throws -> JournalEntry? {
    try database.read { try JournalEntry.fetchOne($0, key: id) }
  }

  func insert(_ entry: JournalEntry) throws -> JournalEntry {
    try database.write { try entry.inserted($0) }
  }

  func save(_ entry: JournalEntry) throws {
    try database.write { try entry.update($0) }
  }
}

extension Folder: FetchableRecord, MutablePersistableRecord {
  public static let databaseTableName = "folder"

  public init(row: Row) throws {
    id = row["id"]
    bookmark = row["bookmark"]
    path = row["path"]
    accessLostAt = row["accessLostAt"]
    missingSince = row["missingSince"]
    createdAt = row["createdAt"]
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id
    container["bookmark"] = bookmark
    container["path"] = path
    container["accessLostAt"] = accessLostAt
    container["missingSince"] = missingSince
    container["createdAt"] = createdAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

extension JournalEntry: FetchableRecord, MutablePersistableRecord {
  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
