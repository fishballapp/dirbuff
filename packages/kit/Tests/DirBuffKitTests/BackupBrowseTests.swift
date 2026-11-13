import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// The backup page against the real restic: a backup listed one folder at a time, what changed or
/// went since marked from the database and the folder as it is, and any file or folder of an
/// older backup put back where it was, or beside what is there now, never over it.
@Suite(.runsRestic) struct BackupBrowseTests {
  private let fixture: BackupFixture
  private let folderID: Int64

  /// Names a shell and a glob both trip over, and some that aren't ASCII.
  private static let awkward = "a b/[x]*?/n [1].txt"
  private static let accented = "café/sub dir/ü.txt"

  init() throws {
    fixture = try BackupFixture()
    folderID = try fixture.addWearing("docs")
    try write("deep", to: Self.awkward)
    try write("accent", to: Self.accented)
    try write("top", to: "top.txt")
    try FileManager.default.createSymbolicLink(
      atPath: url("link").path, withDestinationPath: "top.txt")
  }

  private func url(_ path: String) -> URL {
    fixture.scratch.url.appendingPathComponent("docs").appendingPathComponent(path)
  }

  private func write(_ text: String, to path: String) throws {
    try FileManager.default.createDirectory(
      at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url(path))
  }

  private func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  /// Backs up and returns the backup it made.
  private func backUp() async throws -> KeptBackup {
    try await fixture.run(folderID)
    return try #require(try await fixture.backup.keptBackups(folderID: folderID).first)
  }

  private func items(_ path: String, of backup: KeptBackup) async throws -> [BackupItem] {
    try await fixture.backup.items(in: path, of: backup, folderID: folderID)
  }

  // MARK: Listing

  @Test func aBackupIsListedOneFolderAtATimeByName() async throws {
    let backup = try await backUp()

    let top = try await items("", of: backup)
    #expect(top.map(\.name) == ["a b", "café", "link", "top.txt"])
    #expect(top.map(\.kind) == [.folder, .folder, .link, .file])
    #expect(top.map(\.path) == ["a b", "café", "link", "top.txt"])
    #expect(top.last?.size == 3)
    #expect(top.allSatisfy { $0.sinceThen == nil })

    #expect(try await items("a b", of: backup).map(\.path) == ["a b/[x]*?"])
    let deep = try await items("a b/[x]*?", of: backup)
    #expect(deep.map(\.path) == [Self.awkward])
    #expect(deep.map(\.size) == [4])
    #expect(try await items("café/sub dir", of: backup).map(\.path) == [Self.accented])
  }

  @Test func aFolderTheBackupDoesntHaveSaysSo() async throws {
    let backup = try await backUp()

    await #expect(throws: BackupBuff.Failure.notInBackup("nope")) {
      try await items("nope", of: backup)
    }
  }

  @Test func theBackupsAreTheKeptOnesNewestFirst() async throws {
    let first = try await backUp()
    try write("changed", to: "top.txt")
    let second = try await backUp()

    #expect(try await fixture.backup.keptBackups(folderID: folderID) == [second, first])
  }

  // MARK: Marks

  @Test func whatChangedOrWentSinceABackupIsMarked() async throws {
    let first = try await backUp()
    try write("changed since", to: "top.txt")
    try FileManager.default.removeItem(at: url("café"))

    // Nothing backed up since: the folder as it is says so.
    var top = try await items("", of: first)
    #expect(top.first { $0.name == "top.txt" }?.sinceThen == .changed)
    #expect(top.first { $0.name == "café" }?.sinceThen == .deleted)
    #expect(top.first { $0.name == "a b" }?.sinceThen == nil)

    // A change deep inside a folder, once backed up, marks the folder it is in.
    try write("deeper", to: Self.awkward)
    let second = try await backUp()
    top = try await items("", of: first)
    #expect(top.first { $0.name == "a b" }?.sinceThen == .changed)
    #expect(try await items("a b", of: first).first?.sinceThen == .changed)
    #expect(try await items("a b", of: second).first?.sinceThen == nil)
    // A folder that isn't on this Mac any more: everything in it went.
    #expect(try await items("café/sub dir", of: first).map(\.sinceThen) == [.deleted])
  }

  @Test func aFileThatNeverChangedHasNoVersions() async throws {
    _ = try await backUp()
    try write("changed", to: "top.txt")
    _ = try await backUp()

    #expect(try fixture.backup.history(of: Self.awkward, folderID: folderID).versions.isEmpty)
    #expect(
      try fixture.backup.history(of: "top.txt", folderID: folderID).versions.map(\.change)
        == [.changed, .changed])
  }

  // MARK: Restore

  @Test func aFileOfAnOlderBackupGoesBackUnderItsNameWhenNothingHasIt() async throws {
    let first = try await backUp()
    try FileManager.default.removeItem(at: url(Self.awkward))
    _ = try await backUp()
    let item = try #require(try await items("a b/[x]*?", of: first).first)

    let restored = try await fixture.backup.restore(item, from: first, folderID: folderID)

    #expect(try canonicalPath(of: restored) == canonicalPath(of: url(Self.awkward)))
    #expect(try read(restored) == "deep")
  }

  @Test func aFileWhoseNameIsTakenGoesBesideItWithTheBackupsDate() async throws {
    let first = try await backUp()
    try write("today's", to: Self.accented)
    _ = try await backUp()
    let item = try #require(try await items("café/sub dir", of: first).first)

    let restored = try await fixture.backup.restore(item, from: first, folderID: folderID)
    let again = try await fixture.backup.restore(item, from: first, folderID: folderID)

    let dated = BackupBuff.datedName(of: item, savedAt: first.savedAt)
    #expect(restored.lastPathComponent == dated)
    #expect(
      again.lastPathComponent
        == RestorePlace.copyName(
          of: "ü.txt", savedAt: first.savedAt, number: 2))
    #expect(try read(restored) == "accent")
    #expect(try read(url(Self.accented)) == "today's")
  }

  @Test func aFolderOfAnOlderBackupGoesBackWholeUnderItsNameOrBesideIt() async throws {
    let first = try await backUp()
    try FileManager.default.removeItem(at: url("a b"))
    try write("today's", to: "café/sub dir/ü.txt")
    _ = try await backUp()
    let top = try await items("", of: first)
    let gone = try #require(top.first { $0.name == "a b" })
    let taken = try #require(top.first { $0.name == "café" })

    let restoredGone = try await fixture.backup.restore(gone, from: first, folderID: folderID)
    let restoredTaken = try await fixture.backup.restore(taken, from: first, folderID: folderID)

    #expect(try canonicalPath(of: restoredGone) == canonicalPath(of: url("a b")))
    #expect(try read(url(Self.awkward)) == "deep")
    #expect(restoredTaken.lastPathComponent == "café (\(dateOnly(first.savedAt)))")
    #expect(try contents(of: restoredTaken).keys.sorted() == ["sub dir/ü.txt"])
    #expect(try read(restoredTaken.appendingPathComponent("sub dir/ü.txt")) == "accent")
    #expect(try read(url(Self.accented)) == "today's")
  }

  @Test func aSubfolderComesBackIntoAFolderThatWentToo() async throws {
    let first = try await backUp()
    try FileManager.default.removeItem(at: url("café"))
    let item = try #require(try await items("café", of: first).first)

    let restored = try await fixture.backup.restore(item, from: first, folderID: folderID)

    #expect(try canonicalPath(of: restored) == canonicalPath(of: url("café/sub dir")))
    #expect(try read(url(Self.accented)) == "accent")
  }

  @Test func whatTheBackupDoesntHoldIsNotRestored() async throws {
    let backup = try await backUp()
    let before = try contents(of: url(""))

    await #expect(throws: BackupBuff.Failure.notInBackup("missing.txt")) {
      try await fixture.backup.restore(
        BackupItem(path: "missing.txt", kind: .file), from: backup, folderID: folderID)
    }
    await #expect(throws: BackupBuff.Failure.notInBackup("missing")) {
      try await fixture.backup.restore(
        BackupItem(path: "missing", kind: .folder), from: backup, folderID: folderID)
    }
    #expect(try contents(of: url("")) == before)
  }

  @Test func aFolderBiggerThanTheRoomStopsWithNothingWritten() async throws {
    try fixture.scratch.file("docs/big/a.bin", bytes: 5_000)
    let backup = try await backUp()
    try FileManager.default.removeItem(at: url("big"))
    // restic prints its count each second of a long restore; a few bytes end before the first,
    // so a wrapper prints the one a long restore would.
    let status =
      #"{"message_type":"status","percent_done":0,"total_files":1,"total_bytes":5000}"#
    let cramped = try wrapped(
      beforeRestore: "echo '\(status)'; exec sleep 60", freeSpace: { _ in 1_000 })
    let item = BackupItem(path: "big", kind: .folder)

    await #expect(throws: BackupBuff.Failure.notEnoughRoom(needed: 5_000, available: 1_000)) {
      try await cramped.restore(item, from: backup, folderID: folderID)
    }
    #expect(!exists(url("big")))
  }

  // MARK: Downloads

  @Test func aDownloadGoesExactlyWhereAskedAndNeverReplaces() async throws {
    let backup = try await backUp()
    let place = try fixture.scratch.folder("Desktop")
    try Data("mine".utf8).write(to: place.appendingPathComponent("top.txt"))
    let top = try await items("", of: backup)
    let file = try #require(top.first { $0.name == "top.txt" })
    let folder = try #require(top.first { $0.name == "café" })

    let copy = try await fixture.backup.download(
      file, from: backup, folderID: folderID, to: place.appendingPathComponent("top 2.txt"))
    let folderCopy = try await fixture.backup.download(
      folder, from: backup, folderID: folderID, to: place.appendingPathComponent("Accents"))
    let whole = try await fixture.backup.download(
      BackupItem(path: "", kind: .folder), from: backup, folderID: folderID,
      to: place.appendingPathComponent("docs"))

    #expect(copy.lastPathComponent == "top 2.txt")
    #expect(try read(copy) == "top")
    #expect(try read(folderCopy.appendingPathComponent("sub dir/ü.txt")) == "accent")
    #expect(try read(whole.appendingPathComponent(Self.awkward)) == "deep")
    // Something took the name meanwhile: nothing is written, and what is there stays.
    await #expect(throws: POSIXError(.EEXIST)) {
      try await fixture.backup.download(
        file, from: backup, folderID: folderID, to: place.appendingPathComponent("top.txt"))
    }
    #expect(try read(place.appendingPathComponent("top.txt")) == "mine")
  }

  // MARK: Where a restore writes

  @Test func aRestoreThatWaitedGoesWhereTheFolderIsNowNotWhereItWas() async throws {
    let backup = try await backUp()
    try FileManager.default.removeItem(at: url(Self.awkward))
    let item = try #require(try await items("a b/[x]*?", of: backup).first)
    let hold = Hold()
    let (buff, folderID) = (fixture.backup, folderID)
    // Another command has the gate, as a backup would.
    let holder = Task { try await buff.commands.run { await hold.hold() } }
    await hold.waitUntilHeld()
    let restore = Task { try await buff.restore(item, from: backup, folderID: folderID) }
    // The restore is in the queue behind it, not yet running.
    let queued = try await wait { await buff.commands.waitingCount == 1 }
    #expect(queued, "The restore never queued behind the other command")

    let moved = fixture.scratch.url.appendingPathComponent("docs moved")
    try FileManager.default.moveItem(at: url(""), to: moved)
    await hold.letGo()
    try await holder.value
    let restored = try await restore.value

    #expect(
      try canonicalPath(of: restored)
        == canonicalPath(of: moved.appendingPathComponent(Self.awkward)))
    #expect(!exists(url("")))
  }

  @Test func aFolderReplacedByALinkDuringTheDownloadGetsNothingMadeInIt() async throws {
    let backup = try await backUp()
    try FileManager.default.removeItem(at: url("a b"))
    let outside = try fixture.scratch.folder("outside")
    let item = BackupItem(path: Self.awkward, kind: .file, size: 4)
    // While restic downloads, "a b" comes back as a link out of the folder.
    let swapping = try wrapped(
      beforeRestore: "ln -s '\(outside.path)' '\(url("a b").path)'")

    await #expect(throws: BackupBuff.Failure.self) {
      try await swapping.restore(item, from: backup, folderID: folderID)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  // MARK: What's known

  @Test func theTypedPasswordOpensABackupTheKeychainLostEvenWithTheListingToMake() async throws {
    let first = try await backUp()
    try await fixture.backup.setPassword("correct horse battery")
    try write("changed", to: "top.txt")
    _ = try await backUp()
    try fixture.keychain.delete()
    try fixture.store.setSnapshotListingPending(true)

    await #expect(throws: BackupBuff.Failure.passwordNeeded) {
      try await fixture.backup.keptBackups(folderID: folderID)
    }
    let kept = try await fixture.backup.keptBackups(
      folderID: folderID, password: "correct horse battery")

    #expect(kept.count == 2)
    #expect(try !fixture.store.isSnapshotListingPending())
    let history = try fixture.backup.history(of: "top.txt", folderID: folderID)
    #expect(!history.earlierVersionIsUnknown)
    #expect(history.versions.first?.snapshotID == first.id)
    #expect(history.versions.first?.replacedAt != nil)
    // The page checks a password typed for anything this way.
    await #expect(throws: BackupBuff.Failure.passwordDoesNotOpen) {
      try await fixture.backup.checkPassword("wrong horse")
    }
    try await fixture.backup.checkPassword("correct horse battery")
  }

  @Test func aTypedPasswordOnlyReadsEvenWithAChangeOfPasswordCutShort() async throws {
    let backup = try await backUp()
    try await fixture.backup.setPassword("old horse battery")
    // A change to a new password cut short: both open the backup, the Keychain has the new one.
    try fixture.store.setKeyChangePending(true)
    _ = try await fixture.restic().addKey(newPassword: "new horse battery")
    try fixture.keychain.save("new horse battery", in: .current)

    let top = try await fixture.backup.items(
      in: "", of: backup, folderID: folderID, password: "old horse battery")

    #expect(top.map(\.name) == ["a b", "café", "link", "top.txt"])
    #expect(try fixture.keychain.key() == "new horse battery")
    #expect(try fixture.store.backupAccount()?.isKeyChangePending == true)
    #expect(try await fixture.restic().keys().count == 2)
  }

  @Test func aFolderThatIsntOnThisMacStillBrowsesAndRestoresWhereItsTold() async throws {
    let backup = try await backUp()
    try FileManager.default.removeItem(at: url(""))
    let elsewhere = try fixture.scratch.folder("Elsewhere")

    #expect(!fixture.backup.isFolderOnThisMac(folderID: folderID))
    let top = try await items("", of: backup)
    #expect(top.map(\.sinceThen).allSatisfy { $0 == .unknown })
    let file = try #require(top.first { $0.name == "top.txt" })
    let restored = try await fixture.backup.restore(
      file, from: backup, folderID: folderID, into: elsewhere)
    let folder = try await fixture.backup.restoreFolder(
      folderID: folderID, backup: backup, into: elsewhere)
    await #expect(throws: (any Error).self) {
      try await fixture.backup.restoreFolder(folderID: folderID, backup: backup)
    }

    #expect(try read(restored) == "top")
    #expect(folder.lastPathComponent == "docs (\(dateOnly(backup.savedAt)))")
    #expect(try read(folder.appendingPathComponent(Self.awkward)) == "deep")
  }

  @Test func aFolderMovedDuringTheDownloadIsFollowed() async throws {
    let backup = try await backUp()
    try FileManager.default.removeItem(at: url(Self.awkward))
    let moved = fixture.scratch.url.appendingPathComponent("docs moved")
    let item = BackupItem(path: Self.awkward, kind: .file, size: 4)
    let moving = try wrapped(beforeRestore: "mv '\(url("").path)' '\(moved.path)'")

    let restored = try await moving.restore(item, from: backup, folderID: folderID)

    #expect(
      try canonicalPath(of: restored)
        == canonicalPath(of: moved.appendingPathComponent(Self.awkward)))
    #expect(!exists(url("")))
  }

  @Test func aFolderRemovedFromDirBuffDuringTheDownloadGetsNothing() async throws {
    let backup = try await backUp()
    try FileManager.default.removeItem(at: url(Self.awkward))
    let item = BackupItem(path: Self.awkward, kind: .file, size: 4)
    let engine = fixture.engine
    let folder = try #require(try fixture.store.folder(id: folderID))
    // restic is mid-download until the folder is out of DirBuff: the wrapper says so and waits to
    // be told.
    let reached = fixture.scratch.url.appendingPathComponent("download-begun")
    let release = fixture.scratch.url.appendingPathComponent("download-may-end")
    let removing = try wrapped(
      beforeRestore: """
        touch '\(reached.path)'
        while [ ! -e '\(release.path)' ]; do sleep 0.02; done
        """)
    let id = folderID
    let restore = Task { try await removing.restore(item, from: backup, folderID: id) }
    try await waitForFile(reached)
    try engine.remove(folder)
    try Data().write(to: release)

    await #expect(throws: (any Error).self) { try await restore.value }
    #expect(!exists(url(Self.awkward)))
  }

  @Test func aBackupFindingNoTrackingPointSetsItFromItself() async throws {
    _ = try await backUp()
    try await fixture.store.database.write { db in
      try db.execute(sql: "UPDATE backup SET versionsTrackedSince = NULL")
      try db.execute(sql: "DELETE FROM backupRun")
    }
    try write("changed", to: "top.txt")
    let next = try await backUp()

    #expect(
      try fixture.backup.history(of: "top.txt", folderID: folderID).trackedSince == next.savedAt)
  }

  @Test func rowsFromBeforeTheTrackingPointAreNotRead() async throws {
    _ = try await backUp()
    try write("changed", to: "top.txt")
    let changed = try await backUp()
    try await fixture.store.database.write { db in
      try db.execute(
        sql: "UPDATE backup SET versionsTrackedSince = ?",
        arguments: [changed.savedAt.addingTimeInterval(1)])
    }

    #expect(try fixture.backup.history(of: "top.txt", folderID: folderID).versions.isEmpty)
  }

  @Test func aSeriesTakenOverOffersNothingFromBeforeThisMacFollowedIt() async throws {
    let old = try await backUp()
    try write("changed", to: "top.txt")
    _ = try await backUp()
    let takenOverAt = Date()
    try fixture.store.continueBackupSeries(
      [folderID: try fixture.record(folderID).tag], settings: BackupSettings(), now: takenOverAt)
    _ = try await fixture.backup.keptBackups(folderID: folderID)

    // Nothing followed yet: no version, and the history says since when.
    var history = try fixture.backup.history(of: "top.txt", folderID: folderID)
    #expect(history.versions.isEmpty)
    // Dates are stored to the millisecond.
    #expect(abs(try #require(history.trackedSince).timeIntervalSince(takenOverAt)) < 0.001)

    let firstHere = try await backUp()
    try write("changed again", to: "top.txt")
    _ = try await backUp()
    history = try fixture.backup.history(of: "top.txt", folderID: folderID)

    #expect(history.trackedSince == firstHere.savedAt)
    // The content before the change comes from this Mac's first backup, never the older ones.
    #expect(history.versions.first?.snapshotID == firstHere.id)
    #expect(!history.versions.contains { $0.snapshotID == old.id })
  }

  @Test func aFolderFromBeforeTheColumnIsFollowedFromThisMacsOwnOldestBackup() async throws {
    // Backups this Mac ran itself, each with its History run.
    for text in ["first", "changed"] {
      try write(text, to: "top.txt")
      let runID = try fixture.store.beginBackupRun(folderID: folderID, at: Date())
      try await fixture.run(folderID, runID: runID)
    }
    let first = try #require(try await fixture.backup.keptBackups(folderID: folderID).last)
    try await fixture.store.database.write { db in
      try db.execute(sql: "UPDATE backup SET versionsTrackedSince = NULL")
      try Store.fillVersionsTrackedSince(in: db)
    }

    #expect(
      try fixture.backup.history(of: "top.txt", folderID: folderID).trackedSince == first.savedAt
    )
  }

  @Test func aFolderThatCantBeReadMarksNothing() async throws {
    let backup = try await backUp()
    let locked = url("a b")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }

    #expect(try await items("a b", of: backup).map(\.sinceThen) == [.unknown])
  }

  @Test func aNameChangedOnlyInCaseIsTheSameItemOnACaseInsensitiveVolume() async throws {
    let isCaseSensitive =
      try url("").resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
      .volumeSupportsCaseSensitiveNames ?? true
    try #require(!isCaseSensitive, "the test folder's volume is case-sensitive")
    let backup = try await backUp()
    try FileManager.default.moveItem(at: url("top.txt"), to: url("TOP.txt"))

    let top = try #require(try await items("", of: backup).first { $0.name == "top.txt" })

    #expect(top.sinceThen != .deleted)
  }

  /// This fixture's backup, with restic wrapped in a script that runs `beforeRestore` first.
  private func wrapped(
    beforeRestore: String, freeSpace: @escaping @Sendable (URL) throws -> Int64 = { _ in .max }
  ) throws -> BackupBuff {
    let wrapper = fixture.scratch.url.appendingPathComponent("restic-\(UUID().uuidString)")
    try """
    #!/bin/sh
    case " $* " in *" restore "*) \(beforeRestore) ;; esac
    exec '\(try resticExecutable().path)' "$@"

    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    return BackupBuff(
      engine: fixture.engine, storage: LocalRepository(folder: fixture.repositoryFolder),
      keychain: fixture.keychain, executable: wrapper,
      cacheDirectory: fixture.scratch.url.appendingPathComponent("cache"), home: fixture.home,
      qualityOfService: .userInitiated, freeSpace: freeSpace)
  }

  private func dateOnly(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .omitted)
  }
}
