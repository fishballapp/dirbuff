import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// Every version a file's history lists is one restic can restore, with the right bytes: the ones
/// recorded after each change, and the one before the first of them, which no row holds.
@Suite(.runsRestic) struct BackupVersionBeforeTests {
  /// Writes `text` into the folder's file, with a modification time of its own so a change of the
  /// same size is seen at once.
  private func write(
    _ text: String, to path: String, in fixture: BackupFixture, at seconds: TimeInterval
  ) throws {
    let url = fixture.scratch.url.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + seconds)],
      ofItemAtPath: url.path)
  }

  /// What restoring each version of `path`'s history gives, oldest first; nil for a deletion.
  private func restored(
    _ history: FileHistory, in fixture: BackupFixture, folderID: Int64
  ) async throws -> [String?] {
    var texts: [String?] = []
    for version in history.versions {
      guard version.change != .removed else {
        texts.append(nil)
        continue
      }
      let copy = try await fixture.backup.restore(version, folderID: folderID)
      texts.append(try String(contentsOf: copy, encoding: .utf8))
    }
    return texts
  }

  private func history(_ path: String, in fixture: BackupFixture, folderID: Int64) throws
    -> FileHistory
  {
    try #require(
      try fixture.store.backupFileHistories(folderID: folderID).first { $0.path == path })
  }

  /// Four backups of `a.txt`: "one", "two", "three", "four".
  private func fourBackups(_ fixture: BackupFixture) async throws -> Int64 {
    let folderID = try fixture.addWearing("docs")
    for (index, text) in ["one", "two", "three", "four"].enumerated() {
      try write(text, to: "docs/a.txt", in: fixture, at: TimeInterval(index * 10))
      try await fixture.run(folderID)
    }
    return folderID
  }

  @Test func backUpChangeBackUpChangeBackUpListsThreeContentsAndEachRestoresItsBytes() async throws
  {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    for (index, text) in ["one", "two", "three"].enumerated() {
      try write(text, to: "docs/a.txt", in: fixture, at: TimeInterval(index * 10))
      try await fixture.run(folderID)
    }
    let history = try history("a.txt", in: fixture, folderID: folderID)

    // The first backup has no row, so the first version is the one before the first change.
    #expect(history.versions.count == 3)
    #expect(history.versions[0].replacedAt == history.versions[1].savedAt)
    #expect(history.versions.dropFirst().allSatisfy { $0.replacedAt == nil })
    #expect(history.hasEarlierVersionNotKept == false)
    #expect(
      try await restored(history, in: fixture, folderID: folderID) == ["one", "two", "three"])
  }

  @Test func aFileDeletedLaterHasItsLastContentToRestoreAndADeletionThatHasNone() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    try write("one", to: "docs/a.txt", in: fixture, at: 0)
    try write("keep", to: "docs/b.txt", in: fixture, at: 0)
    try await fixture.run(folderID)
    try FileManager.default.removeItem(
      at: fixture.scratch.url.appendingPathComponent("docs/a.txt"))
    try write("keep, changed", to: "docs/b.txt", in: fixture, at: 10)
    try await fixture.run(folderID)
    let history = try history("a.txt", in: fixture, folderID: folderID)

    #expect(history.versions.map(\.change) == [.changed, .removed])
    #expect(try await restored(history, in: fixture, folderID: folderID) == ["one", nil])
  }

  @Test func aSnapshotThinnedAwayLeavesTheNewestKeptOneBeforeTheChange() async throws {
    let fixture = try BackupFixture()
    let folderID = try await fourBackups(fixture)
    let all = try await fixture.snapshots(folderID).sorted { $0.time < $1.time }
    // "two" is thinned away: "three" is the first change that is still recorded, and "one"
    // is the newest snapshot kept from before it.
    try await fixture.restic().forget(snapshotIDs: [all[1].id])
    try fixture.store.recordForget(
      folderID: folderID, kept: try await fixture.snapshots(folderID), at: Date())
    let history = try history("a.txt", in: fixture, folderID: folderID)

    #expect(history.hasEarlierVersionNotKept == false)
    #expect(
      try await restored(history, in: fixture, folderID: folderID) == ["one", "three", "four"])
  }

  @Test func whenNoEarlierSnapshotIsKeptTheHistoryStartsAtTheFirstRecordedChange() async throws {
    let fixture = try BackupFixture()
    let folderID = try await fourBackups(fixture)
    let all = try await fixture.snapshots(folderID).sorted { $0.time < $1.time }
    try await fixture.restic().forget(snapshotIDs: [all[0].id, all[1].id])
    try fixture.store.recordForget(
      folderID: folderID, kept: try await fixture.snapshots(folderID), at: Date())
    let history = try history("a.txt", in: fixture, folderID: folderID)

    #expect(history.hasEarlierVersionNotKept)
    #expect(try await restored(history, in: fixture, folderID: folderID) == ["three", "four"])
  }

  @Test func aFileAddedInAThinnedSnapshotHasNothingBeforeIt() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    try write("other", to: "docs/other.txt", in: fixture, at: 0)
    try await fixture.run(folderID)
    try write("one", to: "docs/a.txt", in: fixture, at: 10)
    try await fixture.run(folderID)
    try write("two", to: "docs/a.txt", in: fixture, at: 20)
    try await fixture.run(folderID)
    let all = try await fixture.snapshots(folderID).sorted { $0.time < $1.time }
    // The snapshot that added the file is thinned away, and the file isn't in the one before it.
    try await fixture.restic().forget(snapshotIDs: [all[1].id])
    try fixture.store.recordForget(
      folderID: folderID, kept: try await fixture.snapshots(folderID), at: Date())
    let history = try history("a.txt", in: fixture, folderID: folderID)

    #expect(history.versions.map(\.change) == [.added])
    #expect(history.hasEarlierVersionNotKept == false)
    #expect(try await restored(history, in: fixture, folderID: folderID) == ["two"])
  }

  @Test func aFileAddedAndDeletedBetweenKeptSnapshotsLeavesNoHistory() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    try write("other", to: "docs/other.txt", in: fixture, at: 0)
    try await fixture.run(folderID)
    try write("one", to: "docs/a.txt", in: fixture, at: 10)
    try await fixture.run(folderID)
    try FileManager.default.removeItem(
      at: fixture.scratch.url.appendingPathComponent("docs/a.txt"))
    try write("other, changed", to: "docs/other.txt", in: fixture, at: 20)
    try await fixture.run(folderID)
    let all = try await fixture.snapshots(folderID).sorted { $0.time < $1.time }
    try await fixture.restic().forget(snapshotIDs: [all[1].id])
    try fixture.store.recordForget(
      folderID: folderID, kept: try await fixture.snapshots(folderID), at: Date())

    #expect(
      try fixture.store.backupFileHistories(folderID: folderID).contains { $0.path == "a.txt" }
        == false)
  }

  @Test func theSnapshotsAreForgottenWithThePast() async throws {
    let fixture = try BackupFixture()
    let folderID = try await fourBackups(fixture)
    let all = try await fixture.snapshots(folderID).sorted { $0.time < $1.time }
    try await fixture.restic().forget(snapshotIDs: [all[1].id])
    try fixture.store.recordForget(
      folderID: folderID, kept: try await fixture.snapshots(folderID), at: Date())

    #expect(
      try fixture.store.backupSnapshotIDs(folderID: folderID) == [all[0], all[2], all[3]].map(\.id))
  }
}
