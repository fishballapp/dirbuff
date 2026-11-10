import DirBuffCore
import Foundation
import GRDB

/// Temporary's table: a row per folder that wears it, its settings as columns, so a new setting
/// arrives as a migration with a default. Each write touches only the columns it is about, so a
/// copy of the wear taken before a take-off, a licence pause or a run can't write those back.
extension Store {
  func temporaryWear(folderID: Int64) throws -> Wear<TemporarySettings>? {
    try database.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM temporary WHERE folderID = ?", arguments: [folderID])
        .map(Self.temporaryWear)
    }
  }

  /// In the order the folders were added, which is the order a clean-up runs them in.
  func temporaryWearers() throws -> [Wear<TemporarySettings>] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT temporary.* FROM temporary JOIN folder ON folder.id = temporary.folderID
          ORDER BY folder.createdAt, folder.id
          """
      ).map(Self.temporaryWear)
    }
  }

  /// Puts Temporary on with `settings`, or, on a folder that wears it already (paused by the
  /// licence too), keeps its settings and unpauses it. Either way its runs count from `now`.
  func putOnTemporary(folderID: Int64, settings: TemporarySettings, now: Date) throws {
    try database.write {
      try $0.execute(
        sql: """
          INSERT INTO temporary (folderID, rule, maxAgeDays, sizeLimit, disposal, lastRunAt)
          VALUES (:id, :rule, :maxAgeDays, :sizeLimit, :disposal, :now)
          ON CONFLICT (folderID) DO UPDATE SET pausedByLicence = 0, lastRunAt = :now
          """,
        arguments: Self.arguments(settings, folderID: folderID, now: now))
    }
  }

  /// Choosing Empty on restart also counts the folder's runs from `now`, so a restart before the
  /// choice clears nothing (the CASE reads the old rule).
  func saveTemporarySettings(_ settings: TemporarySettings, folderID: Int64, now: Date) throws {
    try database.write {
      try $0.execute(
        sql: """
          UPDATE temporary SET
            lastRunAt = CASE WHEN :rule = 'emptyOnRestart' AND rule != :rule THEN :now
              ELSE lastRunAt END,
            rule = :rule, maxAgeDays = :maxAgeDays, sizeLimit = :sizeLimit, disposal = :disposal
          WHERE folderID = :id
          """,
        arguments: Self.arguments(settings, folderID: folderID, now: now))
    }
  }

  func takeOffTemporary(folderID: Int64) throws {
    try database.write {
      try $0.execute(sql: "DELETE FROM temporary WHERE folderID = ?", arguments: [folderID])
    }
  }

  func setTemporaryPausedByLicence(_ isPaused: Bool, folderID: Int64) throws {
    try database.write {
      try $0.execute(
        sql: "UPDATE temporary SET pausedByLicence = ? WHERE folderID = ?",
        arguments: [isPaused, folderID])
    }
  }

  func recordTemporaryRun(folderID: Int64, at date: Date) throws {
    try database.write {
      try $0.execute(
        sql: "UPDATE temporary SET lastRunAt = ? WHERE folderID = ?", arguments: [date, folderID])
    }
  }

  /// Marks the folder's legacy tag done and, if the tag was there and the folder had a rule, puts
  /// Temporary on with the settings that waited with the tag, in one write. A folder the licence
  /// paused wears it already and is left as it is. Returns false when another read already did it.
  func finishLegacyTag(folderID: Int64, hadTag: Bool) throws -> Bool {
    try database.write { db in
      guard
        let pending = try Row.fetchOne(
          db, sql: "SELECT * FROM legacyTagPending WHERE folderID = ?", arguments: [folderID])
      else { return false }
      try db.execute(sql: "DELETE FROM legacyTagPending WHERE folderID = ?", arguments: [folderID])
      let hadRule: Bool = pending["hadRule"]
      guard hadTag, hadRule else { return true }
      try db.execute(
        sql: """
          INSERT INTO temporary (folderID, rule, maxAgeDays, sizeLimit, disposal, lastRunAt)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT (folderID) DO NOTHING
          """,
        arguments: [
          folderID, pending["rule"], pending["maxAgeDays"], pending["sizeLimit"],
          pending["disposal"], pending["lastRunAt"],
        ])
      return true
    }
  }

  private static func temporaryWear(_ row: Row) throws -> Wear<TemporarySettings> {
    let rule: String = row["rule"]
    guard let rule = Rule(rawValue: rule) else {
      throw DatabaseError(message: "Unknown rule \(rule)")
    }
    let disposal: String = row["disposal"]
    guard let disposal = Disposal(rawValue: disposal) else {
      throw DatabaseError(message: "Unknown disposal \(disposal)")
    }
    return Wear(
      folderID: row["folderID"],
      settings: TemporarySettings(
        rule: rule, maxAgeDays: row["maxAgeDays"], sizeLimit: row["sizeLimit"],
        disposal: disposal),
      isPausedByLicence: row["pausedByLicence"],
      lastRunAt: row["lastRunAt"])
  }

  private static func arguments(_ settings: TemporarySettings, folderID: Int64, now: Date)
    -> StatementArguments
  {
    [
      "id": folderID, "rule": settings.rule.rawValue, "maxAgeDays": settings.maxAgeDays,
      "sizeLimit": settings.sizeLimit, "disposal": settings.chosenDisposal.rawValue, "now": now,
    ]
  }
}
