import Foundation
import GRDB

extension Store {
  /// Whether the snapshots the repository holds still have to be listed into `backupSnapshot`:
  /// after an upgrade, and after taking over a repository whose snapshots this Mac never saw.
  func isSnapshotListingPending() throws -> Bool {
    try database.read { db in
      try Bool.fetchOne(db, sql: "SELECT isPending FROM backupSnapshotListing") ?? false
    }
  }

  func setSnapshotListingPending(_ isPending: Bool) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE backupSnapshotListing SET isPending = ?", arguments: [isPending])
    }
  }

  /// The snapshots restic listed for each folder's series are the ones the repository holds:
  /// they replace what was known, and the listing is done.
  func finishSnapshotListing(_ listed: [Int64: [ResticSnapshot]]) throws {
    try database.write { db in
      try db.execute(sql: "DELETE FROM backupSnapshot")
      for (folderID, snapshots) in listed {
        for snapshot in snapshots {
          try recordBackupSnapshot(
            folderID: folderID, snapshotID: snapshot.id, savedAt: snapshot.time, in: db)
        }
      }
      try Self.fillVersionsTrackedSince(in: db)
      try db.execute(sql: "UPDATE backupSnapshotListing SET isPending = 0")
    }
  }
}
