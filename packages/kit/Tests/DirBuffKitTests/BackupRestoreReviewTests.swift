import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// What reviewing restore found: the Drive a restore lists, what taking over a backup leaves
/// stale, a folder replaced by a file, the snapshots the database trusts, and a cancelled restore.
@Suite struct BackupRestoreReviewTests {
  let drive = InMemoryDrive(pageSize: 100)

  // MARK: Which DirBuff Backup folder is listed

  /// A repository (a folder with a `config`) named `name` in `backups`.
  private func makeMac(_ name: String, in backups: DriveFileID, drive: InMemoryDrive) async throws {
    let mac = try await drive.createFolder(named: name, in: backups)
    _ = try await drive.upload(Data("config".utf8), named: "config", in: mac.id)
  }

  @Test func aRememberedBackupsFolderOfAnotherAccountIsNotTheOneListed() async throws {
    let jo = InMemoryDrive(email: "jo@example.com", pageSize: 100)
    let sam = InMemoryDrive(email: "sam@example.com", pageSize: 100)
    let store = try Store.inMemory()
    // Jo's files have IDs Sam's Drive has never made.
    for number in 0..<5 { _ = try await jo.createFolder(named: "filler \(number)", in: nil) }
    let joBackups = try await jo.createFolder(named: DriveStorage.folderName, in: nil)
    try await makeMac("Jo Mac", in: joBackups.id, drive: jo)
    try store.saveBackupDriveFolder(joBackups.id)
    let samBackups = try await sam.createFolder(named: DriveStorage.folderName, in: nil)
    try await makeMac("Sam Mac", in: samBackups.id, drive: sam)

    let macs = try await DriveStorage(drive: sam, store: store, macName: "New Mac").macs()

    #expect(macs.map(\.name) == ["Sam Mac"])
    // Jo's folder is still the one remembered: only adopting a backup replaces it.
    #expect(try store.backupDriveFolders().backups == joBackups.id)
  }

  @Test func aRememberedBackupsFolderInTheBinFallsBackToTheOneByName() async throws {
    let store = try Store.inMemory()
    let old = try await drive.createFolder(named: DriveStorage.folderName, in: nil)
    try await makeMac("Binned Mac", in: old.id, drive: drive)
    try store.saveBackupDriveFolder(old.id)
    await drive.trash(old.id)
    let live = try await drive.createFolder(named: DriveStorage.folderName, in: nil)
    try await makeMac("Live Mac", in: live.id, drive: drive)

    let macs = try await DriveStorage(drive: drive, store: store, macName: "New Mac").macs()

    #expect(macs.map(\.name) == ["Live Mac"])
    #expect(try store.backupDriveFolders().backups == old.id)
  }

  // MARK: Keep Backing Up Here

  @Test func keepingBackingUpHereOwesEveryFolderAFirstBackupIntoTheNewRepository() async throws {
    let old = try DriveMac("Old Mac", host: "mac-a", drive: drive)
    let oldFolderID = try old.addWearing("Documents")
    try old.write("notes", to: "Documents/a.txt")
    try await old.run(oldFolderID)

    let new = try DriveMac("New Mac", host: "mac-b", drive: drive)
    let ownID = try new.addWearing("Mine")
    try new.write("mine", to: "Mine/b.txt")
    try await new.run(ownID)
    // It was failing, and couldn't read a file.
    try new.store.recordBackupFailure(
      "boom", for: try new.record(ownID), runID: nil, at: Date(timeIntervalSince1970: 1_000))
    try new.store.recordBackup(
      SavedBackup(
        snapshotID: "x", savedAt: Date(), filesNew: 0, filesChanged: 0, bytesAdded: 0,
        skipped: [SkippedFile(path: "b.txt", reason: "denied")], versions: [], cloudOnlyCount: 3),
      for: try new.record(ownID), runID: nil, at: Date())
    #expect(try new.record(ownID).lastSuccessAt != nil)

    let oldMac = try #require(try await new.backup.backedUpMacs().first { !$0.isThisMac })
    let folder = try #require(try await new.backup.backedUpFolders(of: oldMac).first)
    let restored = try await new.backup.restore(
      try #require(folder.snapshots.last), of: folder, from: oldMac,
      into: new.scratch.url.appendingPathComponent("home"))
    let owner = try await DriveAccount(drive: drive, store: new.store).signedInAccount()
    let moment = Date(timeIntervalSince1970: 2_000_000_000)

    try await new.backup.keepBackingUpHere(
      oldMac, continuing: [restored: folder], as: owner, now: moment)
    let restoredID = try require(new.engine.add(restored).id)

    for id in [ownID, restoredID] {
      let record = try new.record(id)
      #expect(record.lastSuccessAt == nil)
      #expect(record.lastSnapshotID == nil)
      #expect(record.lastError == nil)
      #expect(record.failingSince == nil)
      #expect(record.failedRunsInARow == 0)
      #expect(record.skippedCount == 0)
      #expect(record.cloudOnlyCount == 0)
      #expect(record.lastRunAt == moment)
    }
  }

  // MARK: A folder replaced by a file

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

  private func remove(_ path: String, in fixture: BackupFixture) throws {
    try FileManager.default.removeItem(at: fixture.scratch.url.appendingPathComponent(path))
  }

  private func texts(
    _ history: FileHistory, in fixture: BackupFixture, folderID: Int64
  ) async throws -> [String] {
    var texts: [String] = []
    for version in history.versions where version.change != .removed {
      let copy = try await fixture.backup.restore(version, folderID: folderID)
      texts.append(try String(contentsOf: copy, encoding: .utf8))
    }
    return texts
  }

  @Test func aFolderReplacedByAFileIsAddedNotChangedSoNoEarlierVersionIsOffered() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    try write("inside", to: "docs/x/inner.txt", in: fixture, at: 0)
    try write("other", to: "docs/other.txt", in: fixture, at: 0)
    try await fixture.run(folderID)
    try remove("docs/x", in: fixture)
    try write("now a file", to: "docs/x", in: fixture, at: 10)
    try await fixture.run(folderID)

    let history = try #require(
      try fixture.store.backupFileHistories(folderID: folderID).first { $0.path == "x" })

    #expect(history.versions.map(\.change) == [.added])
    #expect(try await texts(history, in: fixture, folderID: folderID) == ["now a file"])
  }

  @Test func aFolderReplacedByAFileStaysAddedThroughForgetsCollapse() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    try write("inside", to: "docs/x/inner.txt", in: fixture, at: 0)
    try await fixture.run(folderID)
    try remove("docs/x", in: fixture)
    try write("one", to: "docs/x", in: fixture, at: 10)
    try await fixture.run(folderID)
    try write("two", to: "docs/x", in: fixture, at: 20)
    try await fixture.run(folderID)
    let all = try await fixture.snapshots(folderID).sorted { $0.time < $1.time }
    try await fixture.restic().forget(snapshotIDs: [all[1].id])
    try fixture.store.recordForget(
      folderID: folderID, kept: try await fixture.snapshots(folderID), at: Date())

    let history = try #require(
      try fixture.store.backupFileHistories(folderID: folderID).first { $0.path == "x" })

    #expect(history.versions.map(\.change) == [.added])
    #expect(try await texts(history, in: fixture, folderID: folderID) == ["two"])
  }

  // MARK: The snapshots the database trusts

  @Test func snapshotsListedAfterAnUpgradeAreOnlyThoseTheRepositoryHolds() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    for (index, text) in ["one", "two", "three", "four"].enumerated() {
      try write(text, to: "docs/a.txt", in: fixture, at: TimeInterval(index * 10))
      try await fixture.run(folderID)
    }
    let all = try await fixture.snapshots(folderID).sorted { $0.time < $1.time }
    // A forget the database never heard of, and a database that has to be told what is kept.
    try await fixture.restic().forget(snapshotIDs: [all[1].id])
    try await fixture.store.database.write { try $0.execute(sql: "DELETE FROM backupSnapshot") }
    try fixture.store.setSnapshotListingPending(true)

    let unknown = try #require(
      try fixture.store.backupFileHistories(folderID: folderID).first { $0.path == "a.txt" })
    #expect(unknown.earlierVersionIsUnknown)
    #expect(unknown.versions.allSatisfy { $0.replacedAt == nil })

    // The next command that opens the repository lists it.
    _ = try await fixture.backup.snapshots(folderID: folderID)

    #expect(try fixture.store.isSnapshotListingPending() == false)
    #expect(
      try fixture.store.backupSnapshotIDs(folderID: folderID) == [all[0], all[2], all[3]].map(\.id))
    let known = try #require(
      try fixture.store.backupFileHistories(folderID: folderID).first { $0.path == "a.txt" })
    #expect(known.earlierVersionIsUnknown == false)
    #expect(known.versions.first?.replacedAt != nil)
    #expect(known.versions.first?.snapshotID == all[0].id)
  }

  // MARK: Restore Folder's series

  @Test func aFoldersSeriesIsTheOneItsBackedUpFolderIsNamedBy() async throws {
    let old = try DriveMac("Old Mac", host: "mac-a", drive: drive)
    let first = try old.addWearing("Documents")
    let second = try old.addWearing("Projects")
    try old.write("a", to: "Documents/a.txt")
    try old.write("b", to: "Projects/b.txt")
    try await old.run(first)
    try await old.run(second)
    let mac = try #require(try await old.backup.backedUpMacs().first)

    let folders = try await old.backup.backedUpFolders(of: mac)

    let (firstSeries, secondSeries) = (
      try old.backup.series(of: first), try old.backup.series(of: second)
    )
    #expect(firstSeries == folders.first { $0.name == "Documents" }?.series)
    #expect(secondSeries == folders.first { $0.name == "Projects" }?.series)
    #expect(firstSeries != secondSeries)
  }

  // MARK: A restore that is cancelled

  @Test func aCancelledRestoreStopsResticAndLeavesNothingBehind() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    try write("saved", to: "docs/a.txt", in: fixture, at: 0)
    try await fixture.run(folderID)
    let snapshot = try #require(try await fixture.snapshots(folderID).last)
    // restic wrapped so a restore writes some of the folder, says so, and then goes on for
    // ever, as a slow download does.
    let wrapper = fixture.scratch.url.appendingPathComponent("restic-slow-restore")
    let real = try resticExecutable().path
    let status =
      #"{"message_type":"status","percent_done":0.1,"total_files":9,"files_restored":1,"total_bytes":900,"bytes_restored":100}"#
    try """
    #!/bin/sh
    case " $* " in *" restore "*)
      target=""
      for argument in "$@"; do
        if [ "$previous" = "--target" ]; then target="$argument"; fi
        previous="$argument"
      done
      mkdir -p "$target/restored" && echo partial > "$target/restored/part"
      echo "$target" > '\(fixture.scratch.url.appendingPathComponent("target.txt").path)'
      echo '\(status)'
      exec sleep 60 ;;
    esac
    exec '\(real)' "$@"

    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    let backup = BackupBuff(
      engine: fixture.engine, storage: LocalRepository(folder: fixture.repositoryFolder),
      keychain: fixture.keychain, executable: wrapper,
      cacheDirectory: fixture.scratch.url.appendingPathComponent("cache"), home: fixture.home,
      qualityOfService: .userInitiated)
    let siblingsBefore = try FileManager.default.contentsOfDirectory(
      atPath: fixture.scratch.url.path)
    let writing = Flag()

    let restore = Task {
      try await backup.restoreFolder(
        folderID: folderID, backup: KeptBackup(snapshot), onProgress: { _ in writing.raise() })
    }
    try await writing.waitUntilRaised()
    restore.cancel()

    await #expect(throws: CancellationError.self) { try await restore.value }
    // restic was writing into a staging folder, which is gone, and nothing was moved into place.
    let staged = try String(
      contentsOf: fixture.scratch.url.appendingPathComponent("target.txt"), encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(!staged.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: staged))
    #expect(
      !FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: staged).deletingLastPathComponent().path))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.scratch.url.path).sorted()
        == (siblingsBefore + ["target.txt"]).sorted())
    // restic is gone, so the next command isn't waiting on its lock or the gate.
    #expect(try await backup.snapshots(folderID: folderID).count == 1)
  }
}

/// Raised once, from restic's progress, for a test that waits on it.
private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var isRaised = false

  func raise() { lock.withLock { isRaised = true } }

  func waitUntilRaised() async throws {
    for _ in 0..<400 {
      if lock.withLock({ isRaised }) { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw CancellationError()
  }
}
