import DirBuffCore
import Foundation
import GRDB
import Testing

@testable import DirBuffKit

/// A database as 0.2.0 left it, Temporary's settings in the folder's columns, opened by this
/// version: every setting and every run in History comes through.
@Suite struct UpgradeFrom020Tests {
  let store: Store
  let nine = Date(timeIntervalSince1970: 1_800_000_000)
  /// The folders by name, as this version reads them.
  let folders: [String: Folder]

  init() throws {
    let database = try DatabaseQueue()
    // The last migration 0.2.0 shipped.
    try Store.migrator.migrate(database, upTo: "runs for the journal from before runs")
    let nine = nine
    try database.write { db in
      // id, path, rule, maxAgeDays, sizeLimit, disposal, wearsTemporary, turnedOffByLicence,
      // lastRunAt, accessLostAt, missingSince
      let folders: [DatabaseValueConvertible?] = [
        1, "Downloads", "age", 14, 10_000_000_000, "bin", true, false, nine, nil, nil,
        2, "Exports", "size", 90, 5_000_000_000, "delete", true, false, nine, nil, nil,
        3, "Scratch", "automatic", 90, 10_000_000_000, "delete", true, false, nine, nine, nil,
        4, "Screenshots", "emptyOnRestart", 90, 10_000_000_000, "bin", true, false, nine, nil, nine,
        5, "Projects", "age", 30, 10_000_000_000, "delete", false, true, nine - 3_600, nil, nil,
        6, "Music", "age", 90, 10_000_000_000, "bin", false, false, nine, nil, nil,
        7, "Old", "size", 90, 2_000_000_000, "delete", false, false, nine - 60, nil, nil,
      ]
      for row in stride(from: 0, to: folders.count, by: 11) {
        let values = Array(folders[row..<row + 11])
        try db.execute(
          sql: """
            INSERT INTO folder (id, bookmark, path, rule, maxAgeDays, sizeLimit, disposal,
              wearsTemporary, turnedOffByLicence, lastRunAt, accessLostAt, missingSince, createdAt)
            VALUES (?1, x'01', '\(fixtureHome)/' || ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            """,
          arguments: StatementArguments(values + [nine - 86_400 + Double(row)]))
      }
      try db.execute(sql: "INSERT INTO legacyTagPending (folderID, hadRule) VALUES (7, 1)")
      try db.execute(
        sql: "INSERT INTO run (id, startedAt) VALUES (1, ?), (2, ?)",
        arguments: [nine, nine + 3_600])
      try db.execute(
        sql: """
          INSERT INTO journalEntry
            (runID, folderID, disposal, name, binnedPath, size, reasons, performedAt, undoneAt)
          VALUES
            (1, 1, 'bin', 'old.zip', '\(fixtureHome)/.Trash/old.zip', 100, '["age"]', ?1, NULL),
            (1, 2, 'delete', 'render.mov', NULL, 4000, '["size"]', ?1, NULL),
            (2, 4, 'bin', 'shot.png', '\(fixtureHome)/.Trash/shot.png', 20, '["emptyOnRestart"]',
              ?2, ?2);
          """,
        arguments: [nine, nine + 3_600])
    }
    store = try Store(database)
    folders = Dictionary(
      uniqueKeysWithValues: try store.folders().map {
        (URL(fileURLWithPath: $0.path).lastPathComponent, $0)
      })
  }

  private func wear(_ name: String) throws -> Wear<TemporarySettings>? {
    try store.temporaryWear(folderID: try #require(folders[name]?.id))
  }

  @Test func keepsEveryFolderAndWhereItIs() throws {
    #expect(
      try store.folders().map(\.path)
        == ["Downloads", "Exports", "Scratch", "Screenshots", "Projects", "Music", "Old"].map {
          "\(fixtureHome)/\($0)"
        })
    #expect(folders["Scratch"]?.accessLostAt == nine)
    #expect(folders["Screenshots"]?.missingSince == nine)
  }

  @Test func keepsEachRuleAndItsSettings() throws {
    #expect(
      try wear("Downloads")
        == Wear(
          folderID: 1, settings: TemporarySettings(rule: .age, maxAgeDays: 14),
          isPausedByLicence: false, lastRunAt: nine))
    #expect(
      try wear("Exports")?.settings
        == TemporarySettings(rule: .size, sizeLimit: 5_000_000_000, disposal: .delete))
    #expect(
      try wear("Scratch")?.settings == TemporarySettings(rule: .automatic, disposal: .delete))
    #expect(try wear("Screenshots")?.settings == TemporarySettings(rule: .emptyOnRestart))
  }

  @Test func keepsAFolderTheLicencePausedPausedWithItsSettings() throws {
    #expect(
      try wear("Projects")
        == Wear(
          folderID: 5, settings: TemporarySettings(maxAgeDays: 30, disposal: .delete),
          isPausedByLicence: true, lastRunAt: nine - 3_600))
  }

  @Test func leavesAFolderThatWoreNothingWearingNothing() throws {
    #expect(try wear("Music") == nil)
    #expect(try store.temporaryWearers().map(\.folderID) == [1, 2, 3, 4, 5])
  }

  @Test func aFolderStillOwingItsTagGetsItsSettingsBackWithTheTag() throws {
    #expect(try wear("Old") == nil)
    #expect(try store.finishLegacyTag(folderID: 7, hadTag: true))
    #expect(
      try wear("Old")
        == Wear(
          folderID: 7,
          settings: TemporarySettings(rule: .size, sizeLimit: 2_000_000_000, disposal: .delete),
          isPausedByLicence: false, lastRunAt: nine - 60))
  }

  @Test func keepsEveryRunInHistory() throws {
    #expect(
      try store.runs() == [
        HistoryRun(id: 2, startedAt: nine + 3_600, shares: [4: .init(itemCount: 1, size: 20)]),
        HistoryRun(
          id: 1, startedAt: nine,
          shares: [1: .init(itemCount: 1, size: 100), 2: .init(itemCount: 1, size: 4000)]),
      ])
    let first = try store.journal(runID: 1)
    #expect(first.map(\.name) == ["old.zip", "render.mov"])
    #expect(first.map(\.binnedPath) == ["\(fixtureHome)/.Trash/old.zip", nil])
    #expect(first.map(\.reasons) == [[.age], [.size]])
    let second = try #require(store.journal(runID: 2).first)
    #expect(second.disposal == .bin && second.undoneAt == nine + 3_600)
    let buffs = try store.database.read {
      try String.fetchAll($0, sql: "SELECT buff FROM run ORDER BY id")
    }
    #expect(buffs == ["temporary", "temporary"])
  }
}
