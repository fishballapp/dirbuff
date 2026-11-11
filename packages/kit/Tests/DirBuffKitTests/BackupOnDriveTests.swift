import CryptoKit
import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// One Mac backing up into a Drive it shares with others: a database, a Keychain and a scratch
/// folder of its own, and the pinned restic.
struct DriveMac {
  let scratch: Scratch
  let engine: Engine
  let keychain = TestKeychain()
  let storage: DriveStorage
  let backup: BackupBuff

  /// With `isConfirmed` false, the user hasn't yet said to back up to the account signed in.
  init(
    _ name: String, host: String, drive: InMemoryDrive, freeSpace: Int64? = nil,
    isConfirmed: Bool = true
  ) throws {
    scratch = try Scratch()
    engine = Engine(store: try Store.inMemory())
    storage = DriveStorage(drive: drive, store: engine.store, macName: name)
    backup = BackupBuff(
      engine: engine, storage: storage, keychain: keychain, executable: try resticExecutable(),
      cacheDirectory: scratch.url.appendingPathComponent("cache"),
      home: scratch.url.appendingPathComponent("home"),
      // Background work crawls on a busy Mac; what runs at that priority is tested on its own.
      qualityOfService: .userInitiated, machineID: { host },
      freeSpace: { folder in try freeSpace ?? BackupBuff.volumeFreeSpace(of: folder) })
    try scratch.folder("home")
    // The user confirmed the account on the sign-in sheet (Start Backup), as the app has them do
    // before anything is backed up.
    if isConfirmed {
      try engine.store.confirmBackupOwner(
        BackupOwner(accountID: "id-\(drive.email)", email: drive.email))
    }
  }

  var store: Store { engine.store }

  /// Adds the folder at `path` in the scratch folder and puts Backup on it; returns its id.
  func addWearing(_ path: String) throws -> Int64 {
    let id = try require(engine.add(try scratch.folder(path)).id)
    try backup.putOn(folderID: id)
    return id
  }

  @discardableResult
  func run(_ folderID: Int64) async throws -> RunSummary {
    try await backup.run(
      engine.locate(folderID: folderID), require(backup.wear(folderID: folderID)),
      context: RunContext(runID: nil, scheduledAt: Date()))
  }

  func record(_ folderID: Int64) throws -> BackupRecord {
    try require(store.backupRecord(folderID: folderID))
  }

  func write(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: scratch.url.appendingPathComponent(path))
  }

  func read(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }
}

extension InMemoryDrive {
  /// The item at `path`, from My Drive down, by name.
  func item(at path: [String]) async throws -> DriveItem? {
    var parent: DriveFileID?
    var found: DriveItem?
    for name in path {
      let candidates =
        if let parent {
          try await allChildren(of: parent)
        } else {
          try await allCreated().filter { $0.parents.isEmpty }
        }
      guard let item = candidates.first(where: { $0.name == name }) else { return nil }
      found = item
      parent = item.id
    }
    return found
  }

  func text(at path: [String]) async throws -> String? {
    guard let item = try await item(at: path), let data = contents(of: item.id) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}

/// Backup into Google Drive through the bridge, restoring from it, and the weekly check, against
/// an in-memory Drive with the real restic.
@Suite struct BackupOnDriveTests {
  let drive = InMemoryDrive(pageSize: 100)

  // MARK: The repository in Drive

  @Test func aBackupGoesIntoTheMacsOwnFolderBesideTheReadmeWithNoPassword() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.scratch.file("docs/a.txt", bytes: 100)

    try await mac.run(folderID)

    #expect(try await drive.text(at: ["DirBuff Backup", "README.txt"]) == BackupReadme.text)
    #expect(try await drive.item(at: ["DirBuff Backup", "Jo's MacBook", "config"]) != nil)
    #expect(
      try await drive.allChildren(
        of: #require(try await drive.item(at: ["DirBuff Backup", "Jo's MacBook"])).id
      ).map(\.name).sorted() == ["config", "data", "index", "keys", "locks", "snapshots"])
    // Downloaded, it opens with stock restic and no password, as the README says.
    let downloaded = mac.scratch.url.appendingPathComponent("download")
    try await download(["DirBuff Backup", "Jo's MacBook"], to: downloaded)
    var stock = try testRestic(in: mac.scratch, password: nil)
    stock.repository = downloaded.path
    #expect(try await stock.snapshots().count == 1)
    let snapshots = try await mac.backup.snapshots(folderID: folderID)
    #expect(snapshots.map(\.hostname) == ["mac-a"])

    // Another Mac of the same name starts a backup of its own beside it.
    let other = try DriveMac("Jo's MacBook", host: "mac-b", drive: drive)
    let otherFolderID = try other.addWearing("docs")
    try other.scratch.file("docs/b.txt")
    try await other.run(otherFolderID)
    let macs = try await other.backup.backedUpMacs()
    #expect(macs.map(\.name) == ["Jo's MacBook", "Jo's MacBook (2)"])
    #expect(macs.map(\.isThisMac) == [false, true])
  }

  @Test func movingOrRenamingTheFoldersInDriveChangesNothing() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.write("first", to: "docs/a.txt")
    try await mac.run(folderID)

    let archive = try await drive.createFolder(named: "Archive", in: nil)
    let backups = try #require(try await drive.item(at: ["DirBuff Backup"]))
    let repository = try #require(try await drive.item(at: ["DirBuff Backup", "Jo's MacBook"]))
    await drive.move(backups.id, into: archive.id, renaming: "Old Backups")
    await drive.move(repository.id, into: backups.id, renaming: "Work Mac")
    try mac.write("second", to: "docs/a.txt")
    try await mac.run(folderID)

    #expect(try await mac.backup.snapshots(folderID: folderID).count == 2)
    #expect(try await drive.item(at: ["DirBuff Backup"]) == nil)
    #expect(
      try await drive.allChildren(of: backups.id).map(\.name).sorted() == [
        "README.txt", "Work Mac",
      ])
  }

  @Test func aPasswordProtectsTheBackupInDriveWithNothingBesideIt() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.scratch.file("docs/a.txt")
    try await mac.run(folderID)

    try await mac.backup.setPassword("correct horse battery")
    try mac.scratch.file("docs/b.txt")
    try await mac.run(folderID)

    #expect(try await drive.item(at: ["DirBuff Backup", "Jo's MacBook", "keys"]) != nil)
    let keys = try #require(try await drive.item(at: ["DirBuff Backup", "Jo's MacBook", "keys"]))
    #expect(try await drive.allChildren(of: keys.id).count == 1)
    #expect(try await mac.backup.snapshots(folderID: folderID).count == 2)
  }

  /// Copies the folder at `path` in Drive to `directory`, as a download of it would.
  private func download(_ path: [String], to directory: URL) async throws {
    try await drive.export(#require(try await drive.item(at: path)).id, to: directory)
  }

  // MARK: Restore on this Mac

  @Test func aCopyOfAnyVersionIsRestoredBesideTheOriginal() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.scratch.folder("docs/work")
    try mac.write("first", to: "docs/work/Report.pages")
    try await mac.run(folderID)
    let first = try #require(try await mac.backup.snapshots(folderID: folderID).last)
    try mac.write("second!", to: "docs/work/Report.pages")
    try await mac.run(folderID)

    let versions = try mac.backup.versions(of: "work/Report.pages", folderID: folderID)
    #expect(versions.map(\.change) == [.changed])
    #expect(versions.map(\.size) == [7])
    let latest = try #require(versions.last)
    // The first snapshot has no versions: a file in it is the version there is.
    let original = BackupVersion(
      path: "work/Report.pages", snapshotID: first.id, savedAt: first.time, change: .added,
      size: 5)

    let firstCopy = try await mac.backup.restoreCopy(original, folderID: folderID)
    let secondCopy = try await mac.backup.restoreCopy(latest, folderID: folderID)

    let work = mac.scratch.url.appendingPathComponent("docs/work")
    #expect(
      firstCopy.lastPathComponent
        == RestorePlace.copyName(of: "Report.pages", savedAt: first.time, number: 1))
    #expect(firstCopy.deletingLastPathComponent().lastPathComponent == "work")
    #expect(try mac.read(firstCopy) == "first")
    #expect(try mac.read(secondCopy) == "second!")
    #expect(try mac.read(work.appendingPathComponent("Report.pages")) == "second!")
    #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).count == 3)
  }

  @Test func aRestoreNeverOverwritesAnything() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.write("saved", to: "docs/notes.txt")
    try await mac.run(folderID)
    let snapshot = try #require(try await mac.backup.snapshots(folderID: folderID).last)
    let version = BackupVersion(
      path: "notes.txt", snapshotID: snapshot.id, savedAt: snapshot.time, change: .added, size: 5)
    let takenName = RestorePlace.copyName(of: "notes.txt", savedAt: snapshot.time, number: 1)
    try mac.write("mine", to: "docs/" + takenName)
    let takenFolder = try mac.scratch.folder(
      RestorePlace.folderName("docs", savedAt: snapshot.time, number: 1))
    try mac.write("mine too", to: takenFolder.lastPathComponent + "/notes.txt")

    let copy = try await mac.backup.restoreCopy(version, folderID: folderID)
    let folder = try await mac.backup.restoreFolder(folderID: folderID, snapshot: snapshot)

    #expect(
      copy.lastPathComponent
        == RestorePlace.copyName(of: "notes.txt", savedAt: snapshot.time, number: 2))
    #expect(try mac.read(copy) == "saved")
    #expect(try mac.read(mac.scratch.url.appendingPathComponent("docs/" + takenName)) == "mine")
    #expect(
      folder.lastPathComponent
        == RestorePlace.folderName("docs", savedAt: snapshot.time, number: 2))
    #expect(try mac.read(takenFolder.appendingPathComponent("notes.txt")) == "mine too")
    let removal = BackupVersion(
      path: "notes.txt", snapshotID: snapshot.id, savedAt: snapshot.time, change: .removed,
      size: nil)
    await #expect(throws: BackupBuff.Failure.nothingToRestore) {
      try await mac.backup.restoreCopy(removal, folderID: folderID)
    }
  }

  @Test func aFolderIsRestoredAsItWasBesideItself() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.scratch.file("docs/a.txt", bytes: 100)
    try mac.scratch.file("docs/deep/b.txt", bytes: 200)
    try await mac.run(folderID)
    let snapshot = try #require(try await mac.backup.snapshots(folderID: folderID).last)
    try FileManager.default.removeItem(at: mac.scratch.url.appendingPathComponent("docs/deep"))

    let restored = try await mac.backup.restoreFolder(folderID: folderID, snapshot: snapshot)

    #expect(
      try canonicalPath(of: restored.deletingLastPathComponent())
        == canonicalPath(of: mac.scratch.url))
    #expect(try contents(of: restored).keys.sorted() == ["a.txt", "deep/b.txt"])
    #expect(
      try contents(of: mac.scratch.url.appendingPathComponent("docs")).keys.sorted() == ["a.txt"])
  }

  @Test func aFolderIsRestoredOnlyWhenItsVolumeHasRoom() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive, freeSpace: 10)
    let folderID = try mac.addWearing("docs")
    try mac.scratch.file("docs/a.txt", bytes: 100)
    try await mac.run(folderID)
    let snapshot = try #require(try await mac.backup.snapshots(folderID: folderID).last)

    await #expect(throws: BackupBuff.Failure.notEnoughRoom(needed: 100, available: 10)) {
      try await mac.backup.restoreFolder(folderID: folderID, snapshot: snapshot)
    }
    let name = RestorePlace.folderName("docs", savedAt: snapshot.time, number: 1)
    #expect(!exists(mac.scratch.url.appendingPathComponent(name)))
  }

  // MARK: Restore from Google Drive

  @Test func aNewMacRestoresAnotherMacsFolderAndKeepsBackingUpIntoItsBackup() async throws {
    let old = try DriveMac("Old Mac", host: "mac-a", drive: drive)
    let oldFolderID = try old.addWearing("Documents")
    try old.write("notes", to: "Documents/notes.txt")
    try randomData(1_000_000).write(
      to: old.scratch.url.appendingPathComponent("Documents/photo.raw"))
    try await old.run(oldFolderID)
    let series = try old.record(oldFolderID).tag

    let new = try DriveMac("New Mac", host: "mac-b", drive: drive)
    let macs = try await new.backup.backedUpMacs()
    #expect(macs.map(\.name) == ["Old Mac"])
    let oldMac = try #require(macs.first)
    let folders = try await new.backup.backedUpFolders(of: oldMac)
    #expect(folders.map(\.name) == ["Documents"])
    #expect(folders.map(\.series) == [series])
    let folder = try #require(folders.first)
    let snapshot = try #require(folder.snapshots.last)
    let place = new.scratch.url.appendingPathComponent("home")

    let restored = try await new.backup.restore(
      snapshot, of: folder, from: oldMac, into: place)

    #expect(
      try contents(of: restored)
        == contents(of: old.scratch.url.appendingPathComponent("Documents")))
    try await new.backup.keepBackingUpHere(oldMac, continuing: [restored: folder])
    let restoredID = try require(new.engine.add(restored).id)

    #expect(try new.keychain.key() == nil)
    #expect(try new.record(restoredID).tag == series)
    let summary = try await new.run(restoredID)
    // The restored bytes are found in the backup: only the folder's listing goes up.
    #expect(summary.bytes < 100_000)
    let snapshots = try await new.backup.snapshots(folderID: restoredID)
    #expect(snapshots.map(\.hostname) == ["mac-a", "mac-a"])
    #expect(try await new.backup.backedUpMacs().map(\.isThisMac) == [true])
    // Nothing of the new Mac's own was made in Drive.
    #expect(try await drive.item(at: ["DirBuff Backup", "New Mac"]) == nil)
  }

  @Test func keepingBackingUpHereMakesTheSignedInAccountTheOwnerWithTheRepository() async throws {
    let old = try DriveMac("Old Mac", host: "mac-a", drive: drive)
    let oldFolderID = try old.addWearing("Documents")
    try old.write("notes", to: "Documents/a.txt")
    try await old.run(oldFolderID)

    let new = try DriveMac("New Mac", host: "mac-b", drive: drive)
    let account = DriveAccount(drive: drive, store: new.store)
    // A new Mac signs in: its account isn't confirmed, and a repository it had is gone.
    try new.store.recordAccountProblem(.unconfirmed, at: Date())
    try new.store.recordAccountProblem(.otherAccount, at: Date())
    try new.store.recordAccountProblem(.backupGone, at: Date())
    let oldMac = try #require(try await new.backup.backedUpMacs().first)
    let folder = try #require(try await new.backup.backedUpFolders(of: oldMac).first)
    let restored = try await new.backup.restore(
      try #require(folder.snapshots.last), of: folder, from: oldMac,
      into: new.scratch.url.appendingPathComponent("home"))
    let owner = try await account.signedInAccount()

    try await new.backup.keepBackingUpHere(oldMac, continuing: [restored: folder], as: owner)

    #expect(try new.store.backupOwner() == owner)
    // Nothing stands against the account or the repository it took over.
    #expect(try new.store.accountProblems().isEmpty)
    #expect(try await account.check() == [])
    #expect(try new.store.backupDriveFolders().repository?.rawValue == oldMac.id)
  }

  @Test func keepingBackingUpHereWithNoOwnerLeavesTheOwnerAsItWas() async throws {
    let old = try DriveMac("Old Mac", host: "mac-a", drive: drive)
    let oldFolderID = try old.addWearing("Documents")
    try old.write("notes", to: "Documents/a.txt")
    let new = try DriveMac("New Mac", host: "mac-b", drive: drive)
    let kept = BackupOwner(accountID: "id-kept", email: "kept@example.com")
    try new.store.confirmBackupOwner(kept)
    try await old.run(oldFolderID)
    let oldMac = try #require(try await new.backup.backedUpMacs().first)

    try await new.backup.keepBackingUpHere(oldMac)

    #expect(try new.store.backupOwner() == kept)
  }

  @Test func anotherMacsBackupWithAPasswordOpensOnlyWithIt() async throws {
    let old = try DriveMac("Old Mac", host: "mac-a", drive: drive)
    let oldFolderID = try old.addWearing("Documents")
    try old.write("notes", to: "Documents/a.txt")
    try await old.run(oldFolderID)
    let password = "correct horse battery"
    try await old.backup.setPassword(password)

    let new = try DriveMac("New Mac", host: "mac-b", drive: drive)
    let oldMac = try #require(try await new.backup.backedUpMacs().first)

    await #expect(throws: BackupBuff.Failure.passwordNeeded) {
      try await new.backup.backedUpFolders(of: oldMac)
    }
    await #expect(throws: BackupBuff.Failure.passwordDoesNotOpen) {
      try await new.backup.backedUpFolders(of: oldMac, password: "not the password")
    }
    let folder = try #require(
      try await new.backup.backedUpFolders(of: oldMac, password: password).first)
    #expect(folder.name == "Documents")
    let restored = try await new.backup.restore(
      #require(folder.snapshots.last), of: folder, from: oldMac,
      into: new.scratch.url.appendingPathComponent("home"), password: password)
    #expect(try new.read(restored.appendingPathComponent("a.txt")) == "notes")

    try await new.backup.keepBackingUpHere(
      oldMac, password: password, continuing: [restored: folder])
    let restoredID = try require(new.engine.add(restored).id)

    #expect(try new.keychain.key() == password)
    #expect(try new.backup.isPasswordProtected())
    #expect(try await new.run(restoredID).failures == 0)
  }

  // MARK: The weekly check

  @Test func theWeeklyCheckFindsAPackDeletedFromDriveBehindItsBack() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.write("small", to: "docs/a.txt")
    try randomData(1_000_000).write(to: mac.scratch.url.appendingPathComponent("docs/b.raw"))
    try await mac.run(folderID)
    let now = Date()
    #expect(try mac.backup.isCheckDue(now: now))

    let whole = try await mac.backup.check(now: now)

    #expect(whole == BackupCheck(checkedAt: now, problem: nil))
    #expect(try !mac.backup.isCheckDue(now: now.addingTimeInterval(86_400)))
    let data = try #require(
      try await drive.item(at: ["DirBuff Backup", "Jo's MacBook", "data"]))
    var packs: [DriveItem] = []
    for shard in try await drive.allChildren(of: data.id) {
      packs += try await drive.allChildren(of: shard.id)
    }
    let pack = try #require(packs.first)
    await drive.remove(pack.id)

    let found = try #require(try await mac.backup.check(now: now.addingTimeInterval(1)))

    #expect(found.problem?.contains("data/\(pack.name.prefix(2))/\(pack.name)") == true)
    let recorded = try #require(try mac.backup.lastCheck())
    #expect(recorded.problem == found.problem)
    #expect(try mac.backup.isCheckDue(now: now.addingTimeInterval(2 + BackupBuff.checkInterval)))
  }

  @Test func theWeeklyCheckFindsAFileGoneFromDriveThatCheckAloneWouldPass() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    for text in ["one", "two"] {
      try mac.write(text, to: "docs/a.txt")
      try await mac.run(folderID)
    }
    let snapshots = try #require(
      try await drive.item(at: ["DirBuff Backup", "Jo's MacBook", "snapshots"]))
    let snapshot = try #require(try await drive.allChildren(of: snapshots.id).first)
    await drive.remove(snapshot.id)

    let found = try #require(try await mac.backup.check())

    #expect(found.problem?.contains("snapshots/" + snapshot.name) == true)
  }

  @Test func theWeeklyCheckRestoresFromSnapshotsOfEveryAgeInTurn() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    for text in ["one", "two", "three"] {
      try mac.write(text, to: "docs/a.txt")
      try await mac.run(folderID)
    }
    let times = try await mac.backup.snapshots(folderID: folderID).map(\.time)

    var sampled: [Date?] = []
    for _ in 0..<4 {
      #expect(try await mac.backup.check()?.isWhole == true)
      sampled.append(try mac.store.backupAccount()?.lastSampledAt)
    }

    // Stored to the millisecond.
    let expected = [times[0], times[1], times[2], times[0]]
    #expect(sampled.count == expected.count)
    for (sampled, expected) in zip(sampled, expected) {
      #expect(abs(try #require(sampled).timeIntervalSince(expected)) < 0.001)
    }
  }
}

@Suite struct BackupCheckSampleTests {
  @Test func theCheckRestoresASmallFileAndComparesItWithItsHash() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: InMemoryDrive(pageSize: 100))
    let folderID = try mac.addWearing("docs")
    try randomData(2_000_000).write(to: mac.scratch.url.appendingPathComponent("docs/big.raw"))
    try mac.scratch.folder("docs/deep")
    try mac.write("small", to: "docs/deep/small.txt")
    try await mac.run(folderID)
    let snapshot = try #require(try await mac.backup.snapshots(folderID: folderID).last)
    let session = try await mac.backup.openRepository(now: Date())

    let sample = try await mac.backup.smallFile(in: snapshot, session: session)

    #expect(sample?.path == "deep/small.txt")
    #expect(
      sample?.hash
        == SHA256.hash(data: Data("small".utf8)).map { String(format: "%02x", $0) }
        .joined())
    #expect(try await mac.backup.sampleProblem(in: snapshot, session: session) == nil)
  }
}
