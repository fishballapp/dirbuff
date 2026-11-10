import Foundation
import GRDB

/// A file or folder of a repository on Drive, as the bridge knows it.
struct RepositoryFile: Equatable, Sendable {
  /// Its path in the repository's layout: `config`, `keys/<name>`, `data/ab/<name>`, or a
  /// folder's (`data/ab`).
  var path: String
  var driveID: DriveFileID
  /// Bytes; nil for a folder.
  var size: Int64?
  /// The bytes of `config` and of a key, kept once read or written: every command reads them,
  /// and neither ever changes.
  var contents: Data?

  var isFolder: Bool { size == nil }
}

/// Bytes that went up to Drive, and when.
struct DriveUpload: Equatable, Sendable {
  var at: Date
  var bytes: Int64
}

extension Store {
  /// The bridge's own migrations, registered after the store's. Each runs once, in order.
  static func registerDriveBridgeMigrations(_ migrator: inout DatabaseMigrator) {
    // A row per Drive file or folder of a repository, so the bridge never looks one up by name.
    // Drive allows duplicate names, so a path may have more than one file (a retried upload whose
    // first reply was lost); they hold the same bytes, since restic names files by their hash.
    migrator.registerMigration("drive bridge") { db in
      try db.create(table: "repositoryFile") { t in
        t.column("repositoryID", .text).notNull()
        t.column("driveID", .text).notNull()
        t.column("path", .text).notNull()
        t.column("size", .integer)
        t.column("contents", .blob)
        t.primaryKey(["repositoryID", "driveID"])
      }
      try db.create(
        index: "repositoryFileByPath", on: "repositoryFile", columns: ["repositoryID", "path"])
      try db.create(table: "driveUpload") { t in
        t.column("at", .datetime).notNull().indexed()
        t.column("bytes", .integer).notNull()
      }
    }
  }

  // MARK: The ID table

  func repositoryFiles(in repository: DriveFileID, at path: String) throws -> [RepositoryFile] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT path, driveID, size, contents FROM repositoryFile
          WHERE repositoryID = ? AND path = ? ORDER BY driveID
          """,
        arguments: [repository.rawValue, path]
      ).map(RepositoryFile.init(row:))
    }
  }

  /// The files (not folders) anywhere under `folder`, each path once.
  func repositoryFiles(in repository: DriveFileID, under folder: String) throws -> [RepositoryFile]
  {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT path, min(driveID) AS driveID, max(size) AS size, NULL AS contents
          FROM repositoryFile
          WHERE repositoryID = ? AND substr(path, 1, ?) = ? AND size IS NOT NULL
          GROUP BY path ORDER BY path
          """,
        arguments: [repository.rawValue, folder.count + 1, folder + "/"]
      ).map(RepositoryFile.init(row:))
    }
  }

  func record(_ file: RepositoryFile, in repository: DriveFileID) throws {
    try database.write { db in
      try db.execute(
        sql: """
          INSERT OR REPLACE INTO repositoryFile (repositoryID, driveID, path, size, contents)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          repository.rawValue, file.driveID.rawValue, file.path, file.size, file.contents,
        ]
      )
    }
  }

  func keepContents(_ contents: Data, of driveID: DriveFileID, in repository: DriveFileID) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE repositoryFile SET contents = ? WHERE repositoryID = ? AND driveID = ?",
        arguments: [contents, repository.rawValue, driveID.rawValue])
    }
  }

  func forgetRepositoryFile(_ driveID: DriveFileID, in repository: DriveFileID) throws {
    try database.write { db in
      try db.execute(
        sql: "DELETE FROM repositoryFile WHERE repositoryID = ? AND driveID = ?",
        arguments: [repository.rawValue, driveID.rawValue])
    }
  }

  /// Makes `files` the whole of what the table knows of the repository.
  func replaceRepositoryFiles(in repository: DriveFileID, with files: [RepositoryFile]) throws {
    try database.write { db in
      try db.execute(
        sql: "DELETE FROM repositoryFile WHERE repositoryID = ?", arguments: [repository.rawValue])
      for file in files {
        try db.execute(
          sql: """
            INSERT OR REPLACE INTO repositoryFile (repositoryID, driveID, path, size)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [repository.rawValue, file.driveID.rawValue, file.path, file.size])
      }
    }
  }

  // MARK: The upload counter

  /// Counts an upload, and forgets those older than `window` before it.
  func recordUpload(_ upload: DriveUpload, keeping window: TimeInterval) throws {
    try database.write { db in
      try db.execute(
        sql: "DELETE FROM driveUpload WHERE at < ?",
        arguments: [upload.at.addingTimeInterval(-window)])
      try db.execute(
        sql: "INSERT INTO driveUpload (at, bytes) VALUES (?, ?)",
        arguments: [upload.at, upload.bytes])
    }
  }

  /// The uploads since `date`, oldest first.
  func uploads(since date: Date) throws -> [DriveUpload] {
    try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT at, bytes FROM driveUpload WHERE at >= ? ORDER BY at",
        arguments: [date]
      ).map { DriveUpload(at: $0["at"], bytes: $0["bytes"]) }
    }
  }
}

extension RepositoryFile {
  fileprivate init(row: Row) {
    self.init(
      path: row["path"], driveID: DriveFileID(row["driveID"] as String), size: row["size"],
      contents: row["contents"])
  }
}
