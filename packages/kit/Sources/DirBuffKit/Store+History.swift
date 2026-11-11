import Foundation
import GRDB

/// A run as History lists it: one clean-up across every folder, and what it removed from each.
public struct HistoryRun: Sendable, Equatable {
  /// What a run removed from one folder.
  public struct Share: Sendable, Equatable {
    public var itemCount: Int
    public var size: Int64

    public init(itemCount: Int, size: Int64) {
      self.itemCount = itemCount
      self.size = size
    }
  }

  public var id: Int64
  public var startedAt: Date
  /// By folder id.
  public var shares: [Int64: Share]

  public init(id: Int64, startedAt: Date, shares: [Int64: Share]) {
    self.id = id
    self.startedAt = startedAt
    self.shares = shares
  }

  /// The folders it removed things from.
  public var folderIDs: Set<Int64> { Set(shares.keys) }
  public var itemCount: Int { shares.values.reduce(0) { $0 + $1.itemCount } }
  public var size: Int64 { shares.values.reduce(0) { $0 + $1.size } }
}

extension Store {
  /// How much History keeps before its oldest runs go.
  public static let historyLimit: Int64 = 100_000_000

  /// What one row is taken to occupy, in SQL over a `journalEntry` row `j` and a `run` row. An
  /// estimate: SQLite stores a row as its values behind a small header, and each index repeats its
  /// column and the row id. So a journal row is its texts' bytes plus about 150 for its numbers,
  /// two dates, header and three index entries; a run's row, a date indexed once, about 70. Free
  /// pages and slack aren't counted: the limit keeps History small, it isn't the file's size.
  private static let journalRowBytes = """
    (150 + length(CAST(j.name AS BLOB)) + coalesce(length(CAST(j.binnedPath AS BLOB)), 0)
      + length(j.reasons))
    """
  private static let runRowBytes = 70

  /// History's own migrations, registered after the store's. Each runs once, in order.
  static func registerHistoryMigrations(_ migrator: inout DatabaseMigrator) {
    // Entries from before runs were recorded become runs, so their History shows. A clean-up runs
    // on the hour and stamps its entries with that hour, so one hour's entries are one clean-up's
    // (dates are stored as UTC text, so the first 13 characters are the hour). An hour that
    // already has a run takes its entries in.
    migrator.registerMigration("runs for the journal from before runs") { db in
      try db.execute(
        sql: """
          INSERT INTO run (startedAt)
            SELECT min(performedAt) FROM journalEntry
            WHERE runID IS NULL AND NOT EXISTS (
              SELECT 1 FROM run
              WHERE substr(run.startedAt, 1, 13) = substr(journalEntry.performedAt, 1, 13))
            GROUP BY substr(performedAt, 1, 13);
          UPDATE journalEntry SET runID = (
            SELECT min(run.id) FROM run
            WHERE substr(run.startedAt, 1, 13) = substr(journalEntry.performedAt, 1, 13))
          WHERE runID IS NULL;
          """)
    }
  }

  /// Registered after Backup's: a run is open from `beginRun` to `endRun`, so no other run's begin
  /// takes it for empty, and a launch finds the ones a quit cut short.
  static func registerOpenRunMigrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("open runs") { db in
      try db.alter(table: "run") { t in
        t.add(column: "isOpen", .boolean).notNull().defaults(to: false)
      }
    }
  }

  /// Every run that removed something, newest first.
  public func runs() throws -> [HistoryRun] {
    try database.read { db in
      Self.summaries(
        try Row.fetchAll(
          db,
          sql: """
            SELECT run.id, run.startedAt, j.folderID, count(*) AS itemCount, sum(j.size) AS size
            FROM run JOIN journalEntry j ON j.runID = run.id
            GROUP BY run.id, j.folderID
            ORDER BY run.startedAt DESC, run.id DESC
            """))
    }
  }

  /// One run, or nil once it's gone (trimmed, cleared, or its folders removed).
  public func run(id: Int64) throws -> HistoryRun? {
    try database.read { db in
      Self.summaries(
        try Row.fetchAll(
          db,
          sql: """
            SELECT run.id, run.startedAt, j.folderID, count(*) AS itemCount, sum(j.size) AS size
            FROM run JOIN journalEntry j ON j.runID = run.id
            WHERE run.id = ?
            GROUP BY j.folderID
            """,
          arguments: [id])
      ).first
    }
  }

  /// Folds one row per run and folder, grouped by run, into one summary per run, in order.
  private static func summaries(_ rows: [Row]) -> [HistoryRun] {
    rows.reduce(into: []) { summaries, row in
      let id: Int64 = row["id"]
      let share = HistoryRun.Share(itemCount: row["itemCount"], size: row["size"])
      if summaries.last?.id == id {
        summaries[summaries.count - 1].shares[row["folderID"]] = share
      } else {
        summaries.append(
          HistoryRun(id: id, startedAt: row["startedAt"], shares: [row["folderID"]: share]))
      }
    }
  }

  /// What a run removed, in the order it went.
  public func journal(runID: Int64) throws -> [JournalEntry] {
    try database.read {
      try JournalEntry.filter(Column("runID") == runID).order(Column("id")).fetchAll($0)
    }
  }

  /// What History takes in the database, as `journalRowBytes` and `runRowBytes` estimate it.
  public func historySize() throws -> Int64 {
    try database.read { db in
      try Int64.fetchOne(
        db,
        sql: """
          SELECT (SELECT count(*) FROM run) * \(Self.runRowBytes)
            + (SELECT coalesce(sum(\(Self.journalRowBytes)), 0) FROM journalEntry j)
          """) ?? 0
    }
  }

  /// Keeps the newest runs that fit in `limit` and forgets the rest, with their entries, but not a
  /// run that is open. Returns how many runs went.
  @discardableResult
  public func trimHistory(to limit: Int64 = Store.historyLimit) throws -> Int {
    try database.write { db in
      try db.execute(
        sql: """
          WITH sized AS (
            SELECT run.id, run.startedAt,
              \(Self.runRowBytes) + coalesce(sum(\(Self.journalRowBytes)), 0) AS bytes
            FROM run LEFT JOIN journalEntry j ON j.runID = run.id
            GROUP BY run.id
          ), kept AS (
            SELECT id, sum(bytes) OVER (ORDER BY startedAt DESC, id DESC) AS upToHere FROM sized
          )
          DELETE FROM run WHERE NOT isOpen AND id IN (SELECT id FROM kept WHERE upToHere > ?)
          """,
        arguments: [limit])
      return db.changesCount
    }
  }

  /// Forgets every finished run and what each removed. A run still going stays, and shows once
  /// it finishes. Nothing in the Bin is touched.
  public func clearHistory() throws {
    try database.write { db in
      try db.execute(
        sql: """
          DELETE FROM journalEntry
          WHERE runID IS NULL OR runID NOT IN (SELECT id FROM run WHERE isOpen);
          DELETE FROM run WHERE NOT isOpen
          """)
    }
  }
}
