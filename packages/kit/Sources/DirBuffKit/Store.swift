import DirBuffCore
import Foundation
import GRDB

/// A folder the user added to DirBuff. It is Temporary while its Finder tag is set.
public struct Folder: Sendable, Equatable {
  public internal(set) var id: Int64?
  /// Finds the folder again after it is renamed or moved. Not security-scoped: the app is not
  /// sandboxed.
  public internal(set) var bookmark: Data
  /// Where the folder was last seen.
  public internal(set) var path: String
  public var settings: TemporarySettings
  /// DirBuff took the folder's tag away when the trial or licence ended; buying offers it back.
  public internal(set) var turnedOffByLicence: Bool
  public internal(set) var createdAt: Date
  /// Starts at `createdAt`, so marking a folder never counts as the first run after a reboot.
  public internal(set) var lastRunAt: Date

  public init(
    id: Int64? = nil,
    bookmark: Data,
    path: String,
    settings: TemporarySettings,
    turnedOffByLicence: Bool = false,
    createdAt: Date,
    lastRunAt: Date
  ) {
    self.id = id
    self.bookmark = bookmark
    self.path = path
    self.settings = settings
    self.turnedOffByLicence = turnedOffByLicence
    self.createdAt = createdAt
    self.lastRunAt = lastRunAt
  }
}

/// One item a run disposed of.
public struct JournalEntry: Sendable, Equatable, Codable {
  public internal(set) var id: Int64?
  public var folderID: Int64
  public var disposal: Disposal
  /// The item's name in its folder. Items are top-level, so this and the folder's bookmark find
  /// where it goes back to, even after the folder is renamed.
  public var name: String
  /// Where the item is in the Bin; nil once deleted. macOS renames an item on a name clash, so
  /// this is the path `trashItem` returned, never a guess.
  public var binnedPath: String?
  public var size: Int64
  public var reasons: Set<Rule>
  public var performedAt: Date
  public var undoneAt: Date?

  public init(
    id: Int64? = nil,
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

  private init(_ database: DatabaseQueue) throws {
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

  /// The user said no to turning the folders back on after buying.
  public func forgetFoldersTurnedOffByLicence() throws {
    try database.write { try $0.execute(sql: "UPDATE folder SET turnedOffByLicence = 0") }
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
    let disposal: String = row["disposal"]
    guard let disposal = Disposal(rawValue: disposal) else {
      throw DatabaseError(message: "Unknown disposal \(disposal)")
    }
    id = row["id"]
    bookmark = row["bookmark"]
    path = row["path"]
    settings = TemporarySettings(
      maxAgeDays: row["maxAgeDays"],
      sizeLimit: row["sizeLimit"],
      automatic: row["automatic"],
      emptyOnRestart: row["emptyOnRestart"],
      disposal: disposal
    )
    turnedOffByLicence = row["turnedOffByLicence"]
    createdAt = row["createdAt"]
    lastRunAt = row["lastRunAt"]
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id
    container["bookmark"] = bookmark
    container["path"] = path
    container["maxAgeDays"] = settings.maxAgeDays
    container["sizeLimit"] = settings.sizeLimit
    container["automatic"] = settings.automatic
    container["emptyOnRestart"] = settings.emptyOnRestart
    container["disposal"] = settings.disposal.rawValue
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
