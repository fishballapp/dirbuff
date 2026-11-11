import CryptoKit
import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// What could go wrong between the steps of Backup's changes, each found in review.
@Suite struct BackupCutShortTests {
  let drive = InMemoryDrive(pageSize: 100)

  // MARK: The password

  @Test func settingTheSamePasswordAgainFinishesAChangeCutShort() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    try fixture.scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    // Cut short after the key was added and the Keychain kept it, before the old key went.
    _ = try await fixture.restic().addKey(newPassword: "correct horse battery")
    try fixture.keychain.save("correct horse battery")

    try await fixture.backup.setPassword("correct horse battery")

    let keys = try await fixture.restic().keys()
    #expect(keys.count == 1)
  }

  // MARK: Keep Backing Up Here

  /// A clean Keep Backing Up Here asks Drive 8 things: each fails in turn, on a Drive of its
  /// own, and the 9th is past the end.
  @Test(arguments: 1...9)
  func keepBackingUpHereCutShortAnywhereChangesNothingOrFinishes(failing number: Int)
    async throws
  {
    let drive = InMemoryDrive(pageSize: 100)
    let old = try DriveMac("Old Mac", host: "mac-a", drive: drive)
    let oldFolderID = try old.addWearing("Documents")
    try old.write("notes", to: "Documents/a.txt")
    try await old.run(oldFolderID)
    let password = "correct horse battery"
    try await old.backup.setPassword(password)
    let new = try DriveMac("New Mac", host: "mac-b", drive: drive)
    let oldMac = try #require(try await new.backup.backedUpMacs().first)
    // A refusal stops nothing else; an unreachable Drive met while restic reads the locks has
    // it list and read them again until its time limit.
    await drive.failCall(
      number: number, with: .rejected(status: 400, reason: nil, message: "refused"))

    do {
      try await new.backup.keepBackingUpHere(oldMac, password: password)
    } catch {
      #expect(try new.keychain.key() == nil)
      #expect(try new.keychain.key(.staged) == nil)
      #expect(try new.store.backupAccount() == nil)
      #expect(try new.store.backupDriveFolders().repository == nil)
      return
    }
    // Finished, whether the refusal came after the last call or restic got over it (a lock it
    // couldn't take off): this Mac backs up as the old one, with its password.
    #expect(try new.keychain.key() == password)
    #expect(try new.store.backupAccount()?.host == "mac-a")
    #expect(try new.store.backupDriveFolders().repository?.rawValue == oldMac.id)
  }

  @Test func aChangeOfPasswordCutShortIsFinishedByTheNextCommand() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    try fixture.scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    // Cut short after the Keychain kept the new password, before the old key (none) went.
    try fixture.store.setKeyChangePending(true)
    _ = try await fixture.restic().addKey(newPassword: "correct horse battery")
    try fixture.keychain.save("correct horse battery")

    try fixture.scratch.file("docs/b.txt")
    try await fixture.run(folderID)

    let keys = try await fixture.restic().keys()
    #expect(keys.count == 1)
    #expect(try fixture.store.backupAccount()?.isKeyChangePending == false)
    // Cut short before the Keychain changed: the new key goes instead.
    try fixture.store.setKeyChangePending(true)
    _ = try await fixture.restic().addKey(newPassword: "never kept anywhere")

    try await fixture.run(folderID)

    #expect(try await fixture.restic().keys().count == 1)
    await #expect(throws: ResticFailure.self) {
      try await testRestic(in: fixture.scratch, password: "never kept anywhere").keys()
    }
  }

  @Test func anAdoptionCutShortAfterTheDatabaseIsFinishedByTheNextCommand() async throws {
    let old = try DriveMac("Old Mac", host: "mac-a", drive: drive)
    let oldFolderID = try old.addWearing("Documents")
    try old.write("notes", to: "Documents/a.txt")
    try await old.run(oldFolderID)
    try await old.backup.setPassword("correct horse battery")
    let new = try DriveMac("New Mac", host: "mac-b", drive: drive)
    let oldMac = try #require(try await new.backup.backedUpMacs().first)
    _ = try await new.storage.repository(of: oldMac)
    // The password staged and the database written; the app quit before the password moved.
    try new.keychain.save("correct horse battery", in: .staged)
    try new.store.adoptBackupRepository(
      host: "mac-a", repository: oldMac.id, series: [:], settings: BackupSettings(),
      now: Date())

    let folders = try await new.backup.snapshots(folderID: try new.addWearing("Restored"))

    #expect(folders.isEmpty)
    #expect(try new.keychain.key() == "correct horse battery")
    #expect(try new.keychain.key(.staged) == nil)
    #expect(try new.store.backupAccount()?.isAdoptionPending == false)
    // Cut short later, with the password moved and the adoption still pending: it stays.
    try new.keychain.save("correct horse battery", in: .staged)
    try new.store.adoptBackupRepository(
      host: "mac-a", repository: oldMac.id, series: [:], settings: BackupSettings(),
      now: Date())

    try new.backup.finishAdoption()

    #expect(try new.keychain.key() == "correct horse battery")
  }

  @Test func twoFoldersCantContinueOneSeries() async throws {
    let old = try DriveMac("Old Mac", host: "mac-a", drive: drive)
    let oldFolderID = try old.addWearing("Documents")
    try old.write("notes", to: "Documents/a.txt")
    try await old.run(oldFolderID)
    let new = try DriveMac("New Mac", host: "mac-b", drive: drive)
    let oldMac = try #require(try await new.backup.backedUpMacs().first)
    let folder = try #require(try await new.backup.backedUpFolders(of: oldMac).first)
    let first = try require(new.engine.add(try new.scratch.folder("one")).id)
    let second = try require(new.engine.add(try new.scratch.folder("two")).id)

    await #expect(throws: BackupBuff.Failure.seriesShared(folder.series)) {
      try await new.backup.keepBackingUpHere(oldMac, continuing: [first: folder, second: folder])
    }
    #expect(try new.store.backupAccount() == nil)
    #expect(try new.store.backupDriveFolders().repository == nil)
  }

  // MARK: The weekly check

  @Test func aConfigLostFromDriveIsRecordedNotThrown() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.write("small", to: "docs/a.txt")
    try await mac.run(folderID)
    let config = try #require(
      try await drive.item(at: ["DirBuff Backup", "Jo's MacBook", "config"]))
    await drive.remove(config.id)

    let found = try #require(try await mac.backup.check())

    #expect(found.problem?.contains("config") == true)
    #expect(try mac.backup.lastCheck()?.problem == found.problem)
    #expect(try !mac.backup.isCheckDue())
  }

  @Test func corruptPacksAreRecordedNotThrown() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.write("small", to: "docs/a.txt")
    try await mac.run(folderID)
    let data = try #require(try await drive.item(at: ["DirBuff Backup", "Jo's MacBook", "data"]))
    for shard in try await drive.allChildren(of: data.id) {
      for pack in try await drive.allChildren(of: shard.id) { await drive.corrupt(pack.id) }
    }

    let found = try #require(try await mac.backup.check())

    #expect(!found.isWhole)
    #expect(try mac.backup.lastCheck()?.problem == found.problem)
  }

  @Test func aDeleteWhoseReplyWasLostIsNotMissing() async throws {
    let fixture = try await BridgeFixture()
    let server = BridgeServer(fixture.bridge)
    let name = String(repeating: "ab", count: 32)
    let post = HTTPRequest(
      method: "POST", path: "/snapshots/\(name)", query: [:], headers: [:], body: Data("s".utf8))
    #expect(await server.respond(to: post).status == 200)
    let file = try #require(try await fixture.filesOnDrive()["snapshots/\(name)"])

    // Drive deletes it, and the reply never comes back.
    await fixture.drive.failNextCall(with: .unreachable)
    let delete = HTTPRequest(
      method: "DELETE", path: "/snapshots/\(name)", query: [:], headers: [:], body: Data())
    _ = await server.respond(to: delete)
    await fixture.drive.remove(file.id)

    #expect(try await fixture.bridge.rebuildTable() == [])
  }

  // MARK: Restores

  @Test func aCopyIsRestoredOnlyWhenItsVolumeHasRoom() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive, freeSpace: 10)
    let folderID = try mac.addWearing("docs")
    try mac.scratch.file("docs/a.txt", bytes: 100)
    try await mac.run(folderID)
    let snapshot = try #require(try await mac.backup.snapshots(folderID: folderID).last)
    let version = BackupVersion(
      path: "a.txt", snapshotID: snapshot.id, savedAt: snapshot.time, change: .added, size: 100)

    await #expect(throws: BackupBuff.Failure.notEnoughRoom(needed: 100, available: 10)) {
      try await mac.backup.restoreCopy(version, folderID: folderID)
    }
  }

  @Test func aCopyIsNeverWrittenThroughALinkOutOfTheFolder() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.scratch.folder("docs/work")
    try mac.write("saved", to: "docs/work/a.txt")
    try await mac.run(folderID)
    let snapshot = try #require(try await mac.backup.snapshots(folderID: folderID).last)
    let outside = try mac.scratch.folder("outside")
    try FileManager.default.removeItem(at: mac.scratch.url.appendingPathComponent("docs/work"))
    try FileManager.default.createSymbolicLink(
      at: mac.scratch.url.appendingPathComponent("docs/work"), withDestinationURL: outside)
    let version = BackupVersion(
      path: "work/a.txt", snapshotID: snapshot.id, savedAt: snapshot.time, change: .added,
      size: 5)

    await #expect(throws: BackupBuff.Failure.self) {
      try await mac.backup.restoreCopy(version, folderID: folderID)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test func aFolderWhoseParentCantBeWrittenIsRestoredWhereTheCallerSays() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let locked = try mac.scratch.folder("Volumes")
    let folderID = try mac.addWearing("Volumes/T7")
    try mac.write("saved", to: "Volumes/T7/a.txt")
    try await mac.run(folderID)
    let snapshot = try #require(try await mac.backup.snapshots(folderID: folderID).last)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }
    await drive.clearCalls()

    await #expect {
      try await mac.backup.restoreFolder(folderID: folderID, snapshot: snapshot)
    } throws: { error in
      guard case BackupBuff.Failure.cannotWrite(let folder) = error else { return false }
      return try canonicalPath(of: folder) == canonicalPath(of: locked)
    }
    // Refused before anything downloaded.
    #expect(!(await drive.calls.contains("download")))
    let elsewhere = try mac.scratch.folder("Restored")

    let restored = try await mac.backup.restoreFolder(
      folderID: folderID, snapshot: snapshot, into: elsewhere)

    #expect(try mac.read(restored.appendingPathComponent("a.txt")) == "saved")
  }

  @Test func aSnapshotOfUnknownSizeIsMeasuredNotTakenAsEmpty() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive, freeSpace: 10)
    let folderID = try mac.addWearing("docs")
    try mac.scratch.file("docs/a.txt", bytes: 100)
    try await mac.run(folderID)
    var snapshot = try #require(try await mac.backup.snapshots(folderID: folderID).last)
    snapshot.size = nil
    let version = BackupVersion(
      path: "a.txt", snapshotID: snapshot.id, savedAt: snapshot.time, change: .added, size: nil)

    await #expect(throws: BackupBuff.Failure.notEnoughRoom(needed: 100, available: 10)) {
      try await mac.backup.restoreFolder(folderID: folderID, snapshot: snapshot)
    }
    await #expect(throws: BackupBuff.Failure.notEnoughRoom(needed: 100, available: 10)) {
      try await mac.backup.restoreCopy(version, folderID: folderID)
    }
  }
}
