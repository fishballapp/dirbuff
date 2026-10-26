import Foundation
import GRDB

@testable import DirBuffKit

/// A store as 0.1.x left it: one folder row for each entry, before the database held Temporary.
/// Opening it migrates it as this version does.
func legacyStore(_ rows: [(bookmark: Data, path: String)]) throws -> Store {
  let database = try DatabaseQueue()
  try Store.migrator.migrate(database, upTo: "licence")
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  try database.write { db in
    for row in rows {
      try db.execute(
        sql: """
          INSERT INTO folder (bookmark, path, automatic, emptyOnRestart, disposal, createdAt,
            lastRunAt)
          VALUES (?, ?, 0, 0, 'bin', ?, ?)
          """,
        arguments: [row.bookmark, row.path, date, date])
    }
  }
  return try Store(database)
}
