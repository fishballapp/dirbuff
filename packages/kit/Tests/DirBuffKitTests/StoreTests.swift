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

  private func folder() throws -> Folder {
    try store.insert(
      Folder(bookmark: Data([1]), path: "/Users/me/Downloads", createdAt: createdAt))
  }

  /// A folder wearing Temporary with `settings`.
  private func wearing(_ settings: TemporarySettings = TemporarySettings()) throws -> Int64 {
    let folderID = try #require(folder().id)
    try store.putOnTemporary(folderID: folderID, settings: settings, now: createdAt)
    return folderID
  }

  @Test func keepsAFolder() throws {
    let saved = try folder()
    #expect(try store.folder(id: try #require(saved.id)) == saved)
    #expect(try store.folders() == [saved])
  }

  @Test func keepsTemporarysSettings() throws {
    let settings = TemporarySettings(
      rule: .size, maxAgeDays: 14, sizeLimit: 5_000_000_000, disposal: .delete)
    let folderID = try wearing(settings)
    #expect(
      try store.temporaryWearers() == [
        Wear(folderID: folderID, settings: settings, isPausedByLicence: false, lastRunAt: createdAt)
      ])
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

  @Test func forgetsAWearTheLicencePausedWhenItIsTakenOff() throws {
    let folderID = try wearing()
    try store.setTemporaryPausedByLicence(true, folderID: folderID)
    try store.takeOffTemporary(folderID: folderID)
    #expect(try store.temporaryWear(folderID: folderID) == nil)
    #expect(try store.folders().map(\.id) == [folderID])
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
    let store = try Store(database)
    #expect(try store.folders().count == 1)
    #expect(try store.temporaryWearers().isEmpty)
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
    let folderID = try wearing()
    #expect(try store.temporaryWear(folderID: folderID) != nil)
    try store.takeOffTemporary(folderID: folderID)
    #expect(try store.temporaryWear(folderID: folderID) == nil)
  }

  @Test func aFolderFromBeforeOwesItsLegacyTagUntilItIsRead() throws {
    let store = try legacyStore([LegacyFolder(bookmark: Data([1]), path: "/Users/me/Downloads")])
    let folderID = try #require(store.folders().first?.id)
    #expect(try store.hasLegacyTag(folderID: folderID))

    #expect(try store.finishLegacyTag(folderID: folderID, hadTag: true))
    #expect(try !store.hasLegacyTag(folderID: folderID))
    #expect(try store.temporaryWear(folderID: folderID) != nil)
  }

  @Test func aLegacyTagIsFinishedOnce() throws {
    let store = try legacyStore([LegacyFolder(bookmark: Data([1]), path: "/Users/me/Downloads")])
    let folderID = try #require(store.folders().first?.id)
    _ = try store.finishLegacyTag(folderID: folderID, hadTag: true)

    #expect(try !store.finishLegacyTag(folderID: folderID, hadTag: false))
    #expect(try store.temporaryWear(folderID: folderID) != nil)
  }

  @Test func aFolderFromBeforeWithNoRuleStaysPlain() throws {
    let store = try legacyStore([
      LegacyFolder(bookmark: Data([1]), path: "/Users/me/Downloads", maxAgeDays: nil)
    ])
    let folderID = try #require(store.folders().first?.id)
    #expect(try store.finishLegacyTag(folderID: folderID, hadTag: true))
    #expect(try store.temporaryWear(folderID: folderID) == nil)
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
    let store = try Store(database)
    let ids = try store.folders().compactMap(\.id)
    #expect(
      try ids.map { try store.temporaryWear(folderID: $0)?.settings } == [
        nil, TemporarySettings(rule: .size, maxAgeDays: 3, sizeLimit: 5, disposal: .delete),
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
    let store = try Store(database)
    let wearers = try store.temporaryWearers()
    #expect(wearers.map(\.folderID) == [try #require(store.folders().last?.id)])
    #expect(wearers.map(\.isPausedByLicence) == [false])
    #expect(wearers.last?.settings.rule == .size)
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
    let store = try legacyStore([legacy])
    let folderID = try #require(store.folders().first?.id)
    #expect(try store.finishLegacyTag(folderID: folderID, hadTag: true))
    let settings = try #require(store.temporaryWear(folderID: folderID)?.settings)
    #expect(settings.rule == rule)
    #expect(settings.maxAgeDays == legacy.maxAgeDays ?? TemporarySettings.defaultMaxAgeDays)
    #expect(settings.sizeLimit == legacy.sizeLimit ?? TemporarySettings.defaultSizeLimit)
  }

  @Test func aFolderAddedNowOwesNoLegacyTag() throws {
    let folderID = try #require(folder().id)
    #expect(try !store.hasLegacyTag(folderID: folderID))
  }

  @Test func recordingARunChangesOnlyItsTime() throws {
    let settings = TemporarySettings(rule: .size, disposal: .delete)
    let folderID = try wearing(settings)
    try store.setTemporaryPausedByLicence(true, folderID: folderID)

    let ran = createdAt.addingTimeInterval(60)
    try store.recordTemporaryRun(folderID: folderID, at: ran)

    #expect(
      try store.temporaryWear(folderID: folderID)
        == Wear(folderID: folderID, settings: settings, isPausedByLicence: true, lastRunAt: ran))
  }
}
