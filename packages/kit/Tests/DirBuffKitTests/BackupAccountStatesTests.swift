import Foundation
import Testing

@testable import DirBuffKit

/// Backup against a Google account that signs the user out, fills up, or loses the backup: the
/// run waits and records nothing as failed, the cause is kept, and the backup goes on once the
/// cause is gone. The real restic, an in-memory Drive.
@Suite struct BackupAccountStatesTests {
  let drive = InMemoryDrive(pageSize: 100)

  /// A Mac with one folder already backed up once.
  func backedUpMac() async throws -> (mac: DriveMac, folderID: Int64) {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.write("first", to: "docs/a.txt")
    try await mac.run(folderID)
    return (mac, folderID)
  }

  func repositoryFolder() async throws -> DriveItem {
    try #require(try await drive.item(at: ["DirBuff Backup", "Jo's MacBook"]))
  }

  /// What the run did to the folder's record: nothing, if it was held.
  func expectHeld(_ mac: DriveMac, _ folderID: Int64, by problem: DriveAccountProblem) async throws
  {
    let before = try mac.record(folderID)
    await #expect(throws: BackupBuff.Failure.accountProblem(problem)) {
      try await mac.run(folderID)
    }
    let after = try mac.record(folderID)
    #expect(after.lastRunAt == before.lastRunAt)
    #expect(after.failedRunsInARow == 0)
    #expect(after.lastError == nil)
  }

  func expectNoProblem(_ mac: DriveMac) async throws {
    #expect(try await DriveAccount(drive: drive, store: mac.store).check() == [])
  }

  // MARK: Held

  @Test func aDriveWithinAGigabyteOfFullHoldsTheRunAndRoomLetsItGo() async throws {
    let (mac, folderID) = try await backedUpMac()
    await drive.setLimit(500_000_000)
    try mac.write("second", to: "docs/a.txt")
    await drive.clearCalls()

    try await expectHeld(mac, folderID, by: .full)

    #expect(try mac.store.accountProblems().keys.sorted { $0.rawValue < $1.rawValue } == [.full])
    // restic wasn't started: nothing but the account was asked.
    #expect(Set(await drive.calls).isSubset(of: ["about", "metadata"]))
    await drive.setLimit(nil)
    try await mac.run(folderID)
    try await expectNoProblem(mac)
    #expect(try await mac.backup.snapshots(folderID: folderID).count == 2)
  }

  @Test func signedOutHoldsTheRun() async throws {
    let (mac, folderID) = try await backedUpMac()
    await drive.failCalls(to: "about", with: .signedOut)
    try await expectHeld(mac, folderID, by: .signedOut)
    await drive.failCalls(to: "about", with: nil)
    try await mac.run(folderID)
    try await expectNoProblem(mac)
  }

  @Test func aDeletedBackupHoldsTheRunWithoutMakingANewOne() async throws {
    let (mac, folderID) = try await backedUpMac()
    await drive.remove(try await repositoryFolder().id)
    await drive.clearCalls()

    try await expectHeld(mac, folderID, by: .backupGone)

    // Nothing was made or uploaded: a new repository would hide that the old one is gone.
    #expect(Set(await drive.calls).isSubset(of: ["about", "metadata"]))
  }

  @Test func aBackupInTheBinHoldsTheRunUntilItIsPutBack() async throws {
    let (mac, folderID) = try await backedUpMac()
    await drive.trash(try await repositoryFolder().id)

    try await expectHeld(mac, folderID, by: .backupInBin)
    try await DriveAccount(drive: drive, store: mac.store).putBack()
    try mac.write("second", to: "docs/a.txt")
    try await mac.run(folderID)

    #expect(try await mac.backup.snapshots(folderID: folderID).count == 2)
    #expect(try mac.store.accountProblems().isEmpty)
  }

  @Test func theUpkeepWaitsToo() async throws {
    let (mac, _) = try await backedUpMac()
    await drive.trash(try await repositoryFolder().id)

    await #expect(throws: BackupBuff.Failure.accountProblem(.backupInBin)) {
      try await mac.backup.maintain()
    }
  }

  @Test func noAnswerFromGoogleIsNotAHold() async throws {
    let (mac, folderID) = try await backedUpMac()
    await drive.failCalls(to: "about", with: .unreachable)
    try mac.write("second", to: "docs/a.txt")
    try await mac.run(folderID)
    #expect(try mac.store.accountProblems().isEmpty)
  }

  // MARK: Mid-run

  @Test func aDriveFillingUpMidRunIsFullAndTheRunIsAFailedOne() async throws {
    let (mac, folderID) = try await backedUpMac()
    try mac.write("second", to: "docs/a.txt")
    await drive.failCalls(to: "upload", with: .storageFull)

    await #expect(throws: BridgeFailure.drive(.storageFull)) { try await mac.run(folderID) }

    #expect(try mac.store.accountProblems().keys.sorted { $0.rawValue < $1.rawValue } == [.full])
    #expect(try mac.record(folderID).failedRunsInARow == 1)
  }

  @Test func theFirstBackupFillingTheDriveBeforeTheRepositoryExistsIsFullToo() async throws {
    let mac = try DriveMac("Jo's MacBook", host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.scratch.file("docs/a.txt", bytes: 1_000)
    await drive.failCalls(to: "upload", with: .storageFull)

    await #expect(throws: DriveProblem.storageFull) { try await mac.run(folderID) }

    #expect(try mac.store.accountProblems().keys.sorted { $0.rawValue < $1.rawValue } == [.full])
  }

  @Test func googleSigningTheUserOutMidRunIsSignedOut() async throws {
    let (mac, folderID) = try await backedUpMac()
    try mac.write("second", to: "docs/a.txt")
    await drive.failCalls(to: "upload", with: .signedOut)

    await #expect(throws: BridgeFailure.drive(.signedOut)) { try await mac.run(folderID) }

    #expect(
      try mac.store.accountProblems().keys.sorted { $0.rawValue < $1.rawValue } == [.signedOut])
  }

  // MARK: Start Again

  @Test func startAgainNeedsTheCallerToConfirm() async throws {
    let (mac, folderID) = try await backedUpMac()
    await drive.remove(try await repositoryFolder().id)
    await #expect(throws: BackupBuff.Failure.notConfirmed) {
      try await mac.backup.startAgain(confirmingHistoryIsLost: false)
    }
    try await expectHeld(mac, folderID, by: .backupGone)
  }

  @Test func startAgainMakesANewBackupAndEveryFolderIsOwedOne() async throws {
    let (mac, folderID) = try await backedUpMac()
    await drive.remove(try await repositoryFolder().id)
    #expect(try await DriveAccount(drive: drive, store: mac.store).check() == [.backupGone])

    try await mac.backup.startAgain(confirmingHistoryIsLost: true)

    #expect(try mac.store.accountProblems().isEmpty)
    let record = try mac.record(folderID)
    #expect(record.lastSuccessAt == nil)
    #expect(record.lastSnapshotID == nil)
    #expect(try mac.store.backupVersions(folderID: folderID).isEmpty)
    #expect(try await mac.backup.snapshots(folderID: folderID).isEmpty)
    #expect(try await drive.item(at: ["DirBuff Backup", "Jo's MacBook", "config"]) != nil)

    try await mac.run(folderID)
    #expect(try await mac.backup.snapshots(folderID: folderID).count == 1)
    try await expectNoProblem(mac)
  }

  @Test func startAgainLeavesTheOldBackupInTheBinAlone() async throws {
    let (mac, _) = try await backedUpMac()
    let old = try await repositoryFolder()
    await drive.trash(old.id)

    try await mac.backup.startAgain(confirmingHistoryIsLost: true)

    #expect(try await drive.metadata(of: old.id).isTrashed)
    #expect(try await drive.item(at: ["DirBuff Backup", "Jo's MacBook"])?.id != old.id)
  }

  @Test func startAgainKeepsAPassword() async throws {
    let (mac, folderID) = try await backedUpMac()
    try await mac.backup.setPassword("correct horse battery")
    await drive.remove(try await repositoryFolder().id)

    try await mac.backup.startAgain(confirmingHistoryIsLost: true)
    try await mac.run(folderID)

    #expect(try mac.backup.isPasswordProtected())
    let keys = try #require(try await drive.item(at: ["DirBuff Backup", "Jo's MacBook", "keys"]))
    #expect(try await drive.allChildren(of: keys.id).count == 1)
    #expect(try await mac.backup.snapshots(folderID: folderID).count == 1)
  }

  @Test func startAgainWorksWhenTheWholeBackupFolderWasDeleted() async throws {
    let (mac, folderID) = try await backedUpMac()
    await drive.remove(try #require(try await drive.item(at: ["DirBuff Backup"])).id)

    try await mac.backup.startAgain(confirmingHistoryIsLost: true)
    try await mac.run(folderID)

    #expect(try await drive.item(at: ["DirBuff Backup", "README.txt"]) != nil)
    #expect(try await mac.backup.snapshots(folderID: folderID).count == 1)
  }

  @Test func startAgainOnAFullDriveChangesNothing() async throws {
    let (mac, folderID) = try await backedUpMac()
    await drive.remove(try await repositoryFolder().id)
    await drive.failCalls(to: "upload", with: .storageFull)

    await #expect(throws: (any Error).self) {
      try await mac.backup.startAgain(confirmingHistoryIsLost: true)
    }

    #expect(try mac.record(folderID).lastSuccessAt != nil)
  }
}
