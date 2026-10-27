import Foundation
import GRDB

@testable import DirBuffKit

/// A folder row as 0.1.x wrote it: its rules could be combined, or all off.
struct LegacyFolder {
  var bookmark: Data
  var path: String
  var maxAgeDays: Int? = 90
  var sizeLimit: Int64? = nil
  var automatic = false
  var emptyOnRestart = false
  var disposal = "bin"
}

/// A store as 0.1.x left it, before the database held Temporary. Opening it migrates it as this
/// version does.
func legacyStore(_ folders: [LegacyFolder]) throws -> Store {
  let database = try DatabaseQueue()
  try Store.migrator.migrate(database, upTo: "licence")
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  try database.write { db in
    for folder in folders {
      try db.execute(
        sql: """
          INSERT INTO folder (bookmark, path, maxAgeDays, sizeLimit, automatic, emptyOnRestart,
            disposal, createdAt, lastRunAt)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          folder.bookmark, folder.path, folder.maxAgeDays, folder.sizeLimit, folder.automatic,
          folder.emptyOnRestart, folder.disposal, date, date,
        ])
    }
  }
  return try Store(database)
}
