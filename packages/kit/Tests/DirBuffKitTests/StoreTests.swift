import DirBuffCore
import Foundation
import GRDB
import Testing

@testable import DirBuffKit

/// The made-up home the store's fixture folders sit in. Only this file spells it, so the public
/// tree's leak check knows it as a fixture.
let fixtureHome = "/Users/me"

@Suite struct StoreTests {
  let store: Store
  let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

  init() throws {
    store = try Store.inMemory()
  }

  private func folder(settings: TemporarySettings = TemporarySettings()) throws -> Folder {
    try store.insert(
      Folder(
        bookmark: Data([1]), path: "/Users/me/Downloads", settings: settings,
        createdAt: createdAt, lastRunAt: createdAt))
  }

  @Test func keepsAFoldersSettings() throws {
    let settings = TemporarySettings(
      rule: .size, maxAgeDays: 14, sizeLimit: 5_000_000_000, disposal: .delete)
    let saved = try folder(settings: settings)
    #expect(try store.folder(id: try #require(saved.id)) == saved)
    #expect(try store.folders().map(\.settings) == [settings])
  }

  @Test func findsAFolderByPath() throws {
    let saved = try folder()
    #expect(try store.folder(path: "/Users/me/Downloads") == saved)
    #expect(try store.folder(path: "/Users/me/Other") == nil)
  }

  @Test func keepsTheJournalNewestFirst() throws {
    let folderID = try #require(folder().id)
    let entries = try [1.0, 2.0].map { offset in
      try store.insert(
        JournalEntry(
          folderID: folderID, disposal: .bin, name: "a", binnedPath: "/b", size: 10,
          reasons: [.age, .size], performedAt: createdAt.addingTimeInterval(offset)))
    }
    #expect(try store.journal(folderID: folderID) == entries.reversed())
  }

  @Test func readsEveryFoldersJournalSinceADate() throws {
    let first = try #require(folder().id)
    let second = try #require(folder().id)
    let entries = try [(first, -10.0), (second, 1.0), (first, 2.0)].map { folderID, offset in
      try store.insert(
        JournalEntry(
          folderID: folderID, disposal: .bin, name: "a", size: 1, reasons: [.age],
          performedAt: createdAt.addingTimeInterval(offset)))
    }
    #expect(try store.journal(since: createdAt) == [entries[2], entries[1]])
  }

  @Test func forgetsAFoldersJournalWithIt() throws {
    let folderID = try #require(folder().id)
    _ = try store.insert(
      JournalEntry(
        folderID: folderID, disposal: .delete, name: "a", size: 1, reasons: [.age],
        performedAt: createdAt))
    try store.deleteFolder(id: folderID)
    #expect(try store.journal(folderID: folderID).isEmpty)
  }

  @Test func startsTheTrialWhenTheDatabaseIsCreated() throws {
    let licence = try store.licence()
    #expect(abs(licence.trialStartedAt.timeIntervalSinceNow) < 60)
    #expect(licence == LicenceRecord(trialStartedAt: licence.trialStartedAt))
  }

  @Test func keepsTheLicence() throws {
    let licence = LicenceRecord(
      trialStartedAt: createdAt, key: "DIRBUFF-1", activationID: "a1",
      lastCheckedAt: createdAt + 60, hasEnded: true)
    try store.save(licence)
    #expect(try store.licence() == licence)
  }

  @Test func forgetsFoldersTurnedOffByLicence() throws {
    var saved = try folder()
    saved.turnedOffByLicence = true
    try store.save(saved)
    try store.forgetFoldersTurnedOffByLicence()
    #expect(try store.folders().map(\.turnedOffByLicence) == [false])
  }

  @Test func addsTheLicenceToADatabaseFromBeforeIt() throws {
    let database = try DatabaseQueue()
    try Store.migrator.migrate(database, upTo: "temporary folders and journal")
    try database.write {
      try $0.execute(
        sql: """
          INSERT INTO folder (bookmark, path, automatic, emptyOnRestart, disposal, createdAt,
            lastRunAt)
          VALUES (x'01', '/Users/me/Downloads', 0, 0, 'bin', ?, ?)
          """,
        arguments: [createdAt, createdAt])
    }
    try Store.migrator.migrate(database)
    let folders = try database.read { try Folder.fetchAll($0) }
    #expect(folders.map(\.turnedOffByLicence) == [false])
    #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM licence") } == 1)
  }

  @Test func remembersWhenAccessWasFirstLostUntilItIsBack() throws {
    let folderID = try #require(folder().id)
    let later = createdAt.addingTimeInterval(3_600)
    try store.recordAccess(folderID: folderID, isLost: true, at: createdAt)
    try store.recordAccess(folderID: folderID, isLost: true, at: later)
    #expect(try store.folder(id: folderID)?.accessLostAt == createdAt)

    try store.recordAccess(folderID: folderID, isLost: false, at: later)
    #expect(try store.folder(id: folderID)?.accessLostAt == nil)
  }

  @Test func keepsWhetherItWearsTemporary() throws {
    var saved = try folder()
    saved.wearsTemporary = true
    try store.save(saved)
    #expect(try store.folder(id: try #require(saved.id)) == saved)
  }

  @Test func aFolderFromBeforeOwesItsLegacyTagUntilItIsRead() throws {
    let store = try legacyStore([LegacyFolder(bookmark: Data([1]), path: "/Users/me/Downloads")])
    let folderID = try #require(store.folders().first?.id)
    #expect(try store.hasLegacyTag(folderID: folderID))

    #expect(try store.finishLegacyTag(folderID: folderID, hadTag: true))
    #expect(try !store.hasLegacyTag(folderID: folderID))
    #expect(try store.folder(id: folderID)?.wearsTemporary == true)
  }

  @Test func aLegacyTagIsFinishedOnce() throws {
    let store = try legacyStore([LegacyFolder(bookmark: Data([1]), path: "/Users/me/Downloads")])
    let folderID = try #require(store.folders().first?.id)
    _ = try store.finishLegacyTag(folderID: folderID, hadTag: true)

    #expect(try !store.finishLegacyTag(folderID: folderID, hadTag: false))
    #expect(try store.folder(id: folderID)?.wearsTemporary == true)
  }

  @Test func aFolderFromBeforeWithNoRuleStaysPlain() throws {
    let store = try legacyStore([
      LegacyFolder(bookmark: Data([1]), path: "/Users/me/Downloads", maxAgeDays: nil)
    ])
    let folderID = try #require(store.folders().first?.id)
    #expect(try store.finishLegacyTag(folderID: folderID, hadTag: true))
    #expect(try store.folder(id: folderID)?.wearsTemporary == false)
  }

  @Test func aFolderTakenOffBeforeForgetsItsSettings() throws {
    let database = try DatabaseQueue()
    try Store.migrator.migrate(database, upTo: "access lost")
    try database.write {
      try $0.execute(
        sql: """
          INSERT INTO folder (bookmark, path, maxAgeDays, sizeLimit, rule, disposal, createdAt,
            lastRunAt, wearsTemporary, takenOffAt, turnedOffByLicence)
          VALUES (x'01', '/taken-off', 3, 5, 'size', 'delete', ?1, ?1, 0, ?1, 0),
            (x'02', '/paused', 3, 5, 'size', 'delete', ?1, ?1, 0, NULL, 1)
          """,
        arguments: [createdAt])
    }
    let folders = try Store(database).folders()
    #expect(
      folders.map(\.settings) == [
        TemporarySettings(),
        TemporarySettings(rule: .size, maxAgeDays: 3, sizeLimit: 5, disposal: .delete),
      ])
  }

  @Test func aFolderWithNoRuleGoesPlainForGood() throws {
    let database = try DatabaseQueue()
    try Store.migrator.migrate(database, upTo: "temporary in the database")
    try database.write {
      try $0.execute(
        sql: """
          INSERT INTO folder (bookmark, path, maxAgeDays, sizeLimit, automatic, emptyOnRestart,
            disposal, createdAt, lastRunAt, wearsTemporary, takenOffAt, turnedOffByLicence)
          VALUES (x'01', '/worn', NULL, NULL, 0, 0, 'bin', ?1, ?1, 1, NULL, 0),
            (x'02', '/taken-off', NULL, NULL, 0, 0, 'delete', ?1, ?1, 0, ?1, 0),
            (x'03', '/licence-paused', NULL, NULL, 0, 0, 'delete', ?1, ?1, 0, NULL, 1),
            (x'04', '/sized', NULL, 5, 0, 0, 'bin', ?1, ?1, 1, NULL, 0)
          """,
        arguments: [createdAt])
    }
    let folders = try Store(database).folders()
    #expect(folders.map(\.wearsTemporary) == [false, false, false, true])
    #expect(folders.map(\.turnedOffByLicence) == [false, false, false, false])
    #expect(folders.last?.settings.rule == .size)
  }

  @Test(arguments: [
    (LegacyFolder(bookmark: Data([1]), path: "/a", maxAgeDays: 30, sizeLimit: 5), Rule.age),
    (LegacyFolder(bookmark: Data([1]), path: "/a", maxAgeDays: nil, sizeLimit: 5), .size),
    (
      LegacyFolder(bookmark: Data([1]), path: "/a", maxAgeDays: nil, emptyOnRestart: true),
      .emptyOnRestart
    ),
    (
      LegacyFolder(
        bookmark: Data([1]), path: "/a", maxAgeDays: nil, automatic: true, disposal: "delete"),
      .automatic
    ),
  ])
  func aFolderFromBeforeKeepsItsFirstRule(legacy: LegacyFolder, rule: Rule) throws {
    let settings = try #require(legacyStore([legacy]).folders().first?.settings)
    #expect(settings.rule == rule)
    #expect(settings.maxAgeDays == legacy.maxAgeDays ?? TemporarySettings.defaultMaxAgeDays)
    #expect(settings.sizeLimit == legacy.sizeLimit ?? TemporarySettings.defaultSizeLimit)
  }

  @Test func aFolderAddedNowOwesNoLegacyTag() throws {
    let folderID = try #require(folder().id)
    #expect(try !store.hasLegacyTag(folderID: folderID))
  }

  @Test func recordingARunChangesOnlyItsTime() throws {
    var saved = try folder()
    let folderID = try #require(saved.id)
    saved.wearsTemporary = true
    try store.save(saved)

    let ran = createdAt.addingTimeInterval(60)
    try store.recordRun(folderID: folderID, at: ran)

    let stored = try #require(try store.folder(id: folderID))
    #expect(stored.lastRunAt == ran)
    #expect(stored.wearsTemporary)
  }
}
