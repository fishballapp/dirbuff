import DirBuffCore
import Foundation
import GRDB

/// A folder the user added to DirBuff. It is Temporary while `wearsTemporary` is set.
public struct Folder: Sendable, Equatable {
  public internal(set) var id: Int64?
  /// Finds the folder again after it is renamed or moved. Not security-scoped: the app is not
  /// sandboxed.
  public internal(set) var bookmark: Data
  /// Where the folder was last seen.
  public internal(set) var path: String
  public var settings: TemporarySettings
  /// Whether the folder is Temporary. DirBuff keeps this itself, so no Finder tag can change it.
  public internal(set) var wearsTemporary: Bool
  /// DirBuff stopped the folder's Temporary when the trial or licence ended; buying offers it back.
  public internal(set) var turnedOffByLicence: Bool

  /// Whether it wears a buff, one the licence paused included. A folder that wears none is never
  /// read or run.
  public var wearsABuff: Bool { wearsTemporary || turnedOffByLicence }
  /// Since when macOS has refused DirBuff access to the folder; nil while it can read it.
  public internal(set) var accessLostAt: Date?
  /// Since when the folder has been missing: deleted, moved to another disk, or moved to the Bin.
  public internal(set) var missingSince: Date?
  public internal(set) var createdAt: Date
  /// Starts at `createdAt`, so marking a folder never counts as the first run after a reboot.
  public internal(set) var lastRunAt: Date

  public init(
    id: Int64? = nil,
    bookmark: Data,
    path: String,
    settings: TemporarySettings,
    wearsTemporary: Bool = false,
    turnedOffByLicence: Bool = false,
    accessLostAt: Date? = nil,
    missingSince: Date? = nil,
    createdAt: Date,
    lastRunAt: Date
  ) {
    self.id = id
    self.bookmark = bookmark
    self.path = path
    self.settings = settings
    self.wearsTemporary = wearsTemporary
    self.turnedOffByLicence = turnedOffByLicence
    self.accessLostAt = accessLostAt
    self.missingSince = missingSince
    self.createdAt = createdAt
    self.lastRunAt = lastRunAt
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

  /// The user said no to turning the folders back on after buying: their settings are forgotten,
  /// as taking a buff off forgets them.
  public func forgetFoldersTurnedOffByLicence() throws {
    try database.write {
      try $0.execute(
        sql: """
          UPDATE folder SET rule = 'age', maxAgeDays = ?, sizeLimit = ?, disposal = 'bin',
            turnedOffByLicence = 0
          WHERE turnedOffByLicence
          """,
        arguments: [TemporarySettings.defaultMaxAgeDays, TemporarySettings.defaultSizeLimit])
    }
  }

  func hasLegacyTag(folderID: Int64) throws -> Bool {
    try database.read {
      try Bool.fetchOne(
        $0, sql: "SELECT EXISTS (SELECT 1 FROM legacyTagPending WHERE folderID = ?)",
        arguments: [folderID]) ?? false
    }
  }

  /// Sets the folder's Temporary from its legacy tag and marks the tag done, in one write: on if
  /// the tag was there and the folder had a rule. Returns false when another read already did it.
  func finishLegacyTag(folderID: Int64, hadTag: Bool) throws -> Bool {
    try database.write { db in
      guard
        let hadRule = try Bool.fetchOne(
          db, sql: "SELECT hadRule FROM legacyTagPending WHERE folderID = ?",
          arguments: [folderID])
      else { return false }
      try db.execute(sql: "DELETE FROM legacyTagPending WHERE folderID = ?", arguments: [folderID])
      try db.execute(
        sql: "UPDATE folder SET wearsTemporary = ? WHERE id = ?",
        arguments: [hadTag && hadRule, folderID])
      return true
    }
  }

  /// Writes only the run's time: a run must not write back a setting the user changed while it ran.
  func recordRun(folderID: Int64, at date: Date) throws {
    try database.write {
      try $0.execute(
        sql: "UPDATE folder SET lastRunAt = ? WHERE id = ?", arguments: [date, folderID])
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

  /// Opens a run: one clean-up across every folder. Returns its id for `Engine.run`. Runs left
  /// empty (a clean-up cut short by a quit, or a removed folder's only run) are dropped first.
  public func beginRun(at date: Date) throws -> Int64 {
    try database.write { db in
      try db.execute(
        sql: "DELETE FROM run WHERE NOT EXISTS (SELECT 1 FROM journalEntry WHERE runID = run.id)")
      try db.execute(sql: "INSERT INTO run (startedAt) VALUES (?)", arguments: [date])
      return db.lastInsertedRowID
    }
  }

  /// Drops a run that removed nothing, so History lists only runs that did something.
  public func dropRunIfEmpty(id: Int64) throws {
    try database.write {
      try $0.execute(
        sql: """
          DELETE FROM run WHERE id = ?
            AND NOT EXISTS (SELECT 1 FROM journalEntry WHERE runID = run.id)
          """,
        arguments: [id])
    }
  }

  /// Writes only the settings columns, so a copy of the folder taken before a Temporary switch or a
  /// licence change can't write those back. Choosing Empty on restart also counts the folder's runs
  /// from `now`, so a restart before the choice clears nothing (the CASE reads the old rule).
  func saveSettings(_ settings: TemporarySettings, folderID: Int64, now: Date) throws {
    try database.write {
      try $0.execute(
        sql: """
          UPDATE folder SET
            lastRunAt = CASE WHEN :rule = 'emptyOnRestart' AND rule != :rule THEN :now
              ELSE lastRunAt END,
            rule = :rule, maxAgeDays = :maxAgeDays, sizeLimit = :sizeLimit, disposal = :disposal
          WHERE id = :id
          """,
        arguments: [
          "rule": settings.rule.rawValue, "now": now, "maxAgeDays": settings.maxAgeDays,
          "sizeLimit": settings.sizeLimit, "disposal": settings.chosenDisposal.rawValue,
          "id": folderID,
        ])
    }
  }

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

/// Settings are columns, not a JSON blob, so a new setting arrives as a migration with a default.
extension Folder: FetchableRecord, MutablePersistableRecord {
  public static let databaseTableName = "folder"

  public init(row: Row) throws {
    let rule: String = row["rule"]
    guard let rule = Rule(rawValue: rule) else {
      throw DatabaseError(message: "Unknown rule \(rule)")
    }
    let disposal: String = row["disposal"]
    guard let disposal = Disposal(rawValue: disposal) else {
      throw DatabaseError(message: "Unknown disposal \(disposal)")
    }
    id = row["id"]
    bookmark = row["bookmark"]
    path = row["path"]
    settings = TemporarySettings(
      rule: rule,
      maxAgeDays: row["maxAgeDays"],
      sizeLimit: row["sizeLimit"],
      disposal: disposal
    )
    wearsTemporary = row["wearsTemporary"]
    accessLostAt = row["accessLostAt"]
    missingSince = row["missingSince"]
    turnedOffByLicence = row["turnedOffByLicence"]
    createdAt = row["createdAt"]
    lastRunAt = row["lastRunAt"]
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id
    container["bookmark"] = bookmark
    container["path"] = path
    container["rule"] = settings.rule.rawValue
    container["maxAgeDays"] = settings.maxAgeDays
    container["sizeLimit"] = settings.sizeLimit
    container["disposal"] = settings.chosenDisposal.rawValue
    container["wearsTemporary"] = wearsTemporary
    container["accessLostAt"] = accessLostAt
    container["missingSince"] = missingSince
    container["turnedOffByLicence"] = turnedOffByLicence
    container["createdAt"] = createdAt
    container["lastRunAt"] = lastRunAt
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
