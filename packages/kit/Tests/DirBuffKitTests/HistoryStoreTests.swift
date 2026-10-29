import DirBuffCore
import Foundation
import GRDB
import Testing

@testable import DirBuffKit

@Suite struct HistoryStoreTests {
  let store: Store
  let nine = Date(timeIntervalSince1970: 1_800_000_000).wholeHour

  init() throws {
    store = try Store.inMemory()
  }

  private func folder(_ name: String) throws -> Int64 {
    try #require(
      store.insert(
        Folder(
          bookmark: Data([1]), path: "\(fixtureHome)/\(name)", settings: TemporarySettings(),
          createdAt: nine, lastRunAt: nine)
      ).id)
  }

  @discardableResult
  private func entry(
    _ name: String, folderID: Int64, runID: Int64?, size: Int64 = 100, at date: Date? = nil
  ) throws -> JournalEntry {
    try store.insert(
      JournalEntry(
        runID: runID, folderID: folderID, disposal: .bin, name: name,
        binnedPath: "\(fixtureHome)/.Trash/\(name)", size: size, reasons: [.age],
        performedAt: date ?? nine))
  }

  @Test func listsRunsNewestFirstWithWhatEachRemoved() throws {
    let downloads = try folder("Downloads")
    let screenshots = try folder("Screenshots")
    let first = try store.beginRun(at: nine)
    try entry("a", folderID: downloads, runID: first, size: 10)
    try entry("b", folderID: downloads, runID: first, size: 20)
    try entry("c", folderID: screenshots, runID: first, size: 30)
    let second = try store.beginRun(at: nine.addingTimeInterval(3_600))
    try entry("d", folderID: screenshots, runID: second, size: 5)

    #expect(
      try store.runs() == [
        RunSummary(
          id: second, startedAt: nine.addingTimeInterval(3_600),
          shares: [screenshots: .init(itemCount: 1, size: 5)]),
        RunSummary(
          id: first, startedAt: nine,
          shares: [
            downloads: .init(itemCount: 2, size: 30), screenshots: .init(itemCount: 1, size: 30),
          ]),
      ])
    #expect(try store.run(id: first)?.itemCount == 3)
    #expect(try store.run(id: first)?.size == 60)
    #expect(try store.run(id: first)?.folderIDs == [downloads, screenshots])
    #expect(try store.journal(runID: first).map(\.name) == ["a", "b", "c"])
  }

  @Test func leavesOutARunWithNothingLeftInIt() throws {
    let downloads = try folder("Downloads")
    let run = try store.beginRun(at: nine)
    try entry("a", folderID: downloads, runID: run)
    try store.deleteFolder(id: downloads)

    #expect(try store.runs().isEmpty)
    #expect(try store.run(id: run) == nil)
  }

  @Test func trimsTheOldestRunsPastTheLimit() throws {
    let downloads = try folder("Downloads")
    let runs = try (0..<4).map { hour in
      let run = try store.beginRun(at: nine.addingTimeInterval(Double(hour) * 3_600))
      try entry("item\(hour)", folderID: downloads, runID: run)
      return run
    }
    let eachRun = try store.historySize() / 4

    #expect(try store.trimHistory(to: eachRun * 2) == 2)
    #expect(try store.runs().map(\.id) == [runs[3], runs[2]])
    #expect(try store.journal(folderID: downloads).map(\.name) == ["item3", "item2"])
    #expect(try store.trimHistory(to: eachRun * 2) == 0)
  }

  @Test func measuresWhatEachRowHolds() throws {
    let downloads = try folder("Downloads")
    let run = try store.beginRun(at: nine)
    let empty = try store.historySize()
    try entry("short", folderID: downloads, runID: run)
    let short = try store.historySize() - empty
    try entry(String(repeating: "long", count: 50), folderID: downloads, runID: run)
    let long = try store.historySize() - empty - short

    #expect(empty == 70)
    #expect(short > 150)
    // The long name is in the row twice, as its name and in its path in the Bin.
    #expect(long - short == 2 * (200 - 5))
  }

  @Test func clearsEveryRunAndEntry() throws {
    let downloads = try folder("Downloads")
    let run = try store.beginRun(at: nine)
    try entry("a", folderID: downloads, runID: run)

    try store.clearHistory()

    #expect(try store.runs().isEmpty)
    #expect(try store.journal(folderID: downloads).isEmpty)
    #expect(try store.historySize() == 0)
  }

  @Test func clearingKeepsTheRunACleanUpIsWriting() throws {
    let downloads = try folder("Downloads")
    let finished = try store.beginRun(at: nine)
    try entry("a", folderID: downloads, runID: finished)
    try entry("old", folderID: downloads, runID: nil)
    let open = try store.beginRun(at: nine.addingTimeInterval(3_600))
    try entry("b", folderID: downloads, runID: open)

    try store.clearHistory(keeping: open)
    try entry("c", folderID: downloads, runID: open)

    #expect(try store.runs().map(\.id) == [open])
    #expect(try store.journal(folderID: downloads).map(\.name) == ["c", "b"])
  }

  @Test func groupsEntriesFromBeforeRunsByTheirHour() throws {
    let database = try DatabaseQueue()
    try Store.migrator.migrate(database, upTo: "runs and missing folders")
    let ten = nine.addingTimeInterval(3_600)
    let eleven = nine.addingTimeInterval(7_200)
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO folder (bookmark, path, maxAgeDays, sizeLimit, disposal, createdAt,
            lastRunAt)
          VALUES (?, ?, 90, NULL, 'bin', ?, ?), (?, ?, 90, NULL, 'bin', ?, ?)
          """,
        arguments: [
          Data([1]), "\(fixtureHome)/Downloads", nine, nine,
          Data([2]), "\(fixtureHome)/Screenshots", nine, nine,
        ])
      // Eleven o'clock already has a run, recorded by this version.
      try db.execute(sql: "INSERT INTO run (startedAt) VALUES (?)", arguments: [eleven])
      for (name, folderID, date) in [
        ("a", 1, nine), ("b", 2, nine), ("c", 1, ten.addingTimeInterval(2)), ("d", 1, eleven),
      ] {
        try db.execute(
          sql: """
            INSERT INTO journalEntry (folderID, disposal, name, size, reasons, performedAt)
            VALUES (?, 'bin', ?, 1, '["age"]', ?)
            """,
          arguments: [folderID, name, date])
      }
    }
    let store = try Store(database)

    let runs = try store.runs()
    #expect(runs.map(\.startedAt) == [eleven, ten.addingTimeInterval(2), nine])
    #expect(runs.map(\.folderIDs) == [[1], [1], [1, 2]])
    #expect(runs[0].id == 1)
    #expect(try store.journal(runID: runs[2].id).map(\.name) == ["a", "b"])
  }
}

extension Date {
  /// The hour this falls in, as a clean-up stamps its entries.
  fileprivate var wholeHour: Date {
    Date(timeIntervalSince1970: (timeIntervalSince1970 / 3_600).rounded(.down) * 3_600)
  }
}
