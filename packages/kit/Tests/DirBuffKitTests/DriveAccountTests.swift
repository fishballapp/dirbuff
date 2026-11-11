import Foundation
import Testing

@testable import DirBuffKit

/// The Google account's states: what the hourly check and a failed command turn into
/// `DriveAccountProblem`s, and what clears them. No restic: a repository's folder and `config` in
/// an in-memory Drive stand in for one.
@Suite struct DriveAccountTests {
  let drive = InMemoryDrive(pageSize: 100)
  let store: Store
  let repository: DriveFileID
  let config: DriveFileID
  let began = Date(timeIntervalSince1970: 1_800_000_000)

  init() async throws {
    store = try Store.inMemory()
    let backups = try await drive.createFolder(named: "DirBuff Backup", in: nil)
    repository = try await drive.createFolder(named: "Test Mac", in: backups.id).id
    config = try await drive.upload(Data("config".utf8), named: "config", in: repository).id
    try store.saveBackupDriveRepository(repository)
    try store.record(RepositoryFile(path: "config", driveID: config, size: 6), in: repository)
  }

  /// An account whose clock is `elapsed` seconds after `began`.
  func account(after elapsed: TimeInterval = 0) -> DriveAccount {
    DriveAccount(drive: drive, store: store, now: { [began] in began.addingTimeInterval(elapsed) })
  }

  // MARK: The hourly check

  @Test func aWholeBackupWithRoomHasNoProblem() async throws {
    #expect(try await account().check() == [])
    #expect(try store.accountProblems().isEmpty)
  }

  @Test func aDriveWithNoLimitIsNeverFull() async throws {
    await drive.setLimit(nil)
    #expect(try await account().check() == [])
  }

  @Test func googleRefusingTheTokenIsSignedOutSinceThen() async throws {
    await drive.failCalls(to: "about", with: .signedOut)
    #expect(try await account(after: 10).check() == [.signedOut])
    #expect(try store.accountProblems() == [.signedOut: began.addingTimeInterval(10)])
    // The next hour finds it still so: it began at the first.
    #expect(try await account(after: 3_610).check() == [.signedOut])
    #expect(try store.accountProblems()[.signedOut] == began.addingTimeInterval(10))
  }

  @Test func signingInAgainClearsSignedOut() async throws {
    await drive.failCalls(to: "about", with: .signedOut)
    try await account().check()
    await drive.failCalls(to: "about", with: nil)
    #expect(try await account().check() == [])
  }

  @Test func aDriveWithinAGigabyteOfFullIsFull() async throws {
    await drive.setLimit(DriveAccount.roomNeeded - 1 + 6)
    #expect(try await account(after: 5).check() == [.full])
    #expect(try store.accountProblems()[.full] == began.addingTimeInterval(5))
  }

  @Test func aGigabyteFreeIsRoomEnough() async throws {
    await drive.setLimit(DriveAccount.roomNeeded + 6)
    #expect(try await account().check() == [])
  }

  @Test func makingRoomClearsFull() async throws {
    await drive.setLimit(1_000)
    try await account().check()
    await drive.setLimit(50_000_000_000)
    #expect(try await account().check() == [])
  }

  @Test func aRepositoryFolderDeletedFromDriveIsGone() async throws {
    await drive.remove(repository)
    #expect(try await account().check() == [.backupGone])
  }

  @Test func aConfigDeletedFromDriveIsGone() async throws {
    await drive.remove(config)
    #expect(try await account().check() == [.backupGone])
  }

  @Test func aRepositoryFolderInTheBinIsInTheBin() async throws {
    await drive.trash(repository)
    #expect(try await account().check() == [.backupInBin])
  }

  @Test func aConfigInTheBinAloneIsInTheBin() async throws {
    await drive.trash(config)
    #expect(try await account().check() == [.backupInBin])
  }

  @Test func aSecondCopyOfConfigIsAsGoodAsTheFirst() async throws {
    let copy = try await drive.upload(Data("config".utf8), named: "config", in: repository).id
    try store.record(RepositoryFile(path: "config", driveID: copy, size: 6), in: repository)
    await drive.remove(config)
    #expect(try await account().check() == [])
  }

  @Test func theBackupBeingPutBackOrMadeAgainClearsTheProblem() async throws {
    await drive.trash(repository)
    try await account().check()
    _ = try await drive.untrash(repository)
    #expect(try await account().check() == [])
  }

  @Test func theBackupGoingFromTheBinToDeletedChangesTheState() async throws {
    await drive.trash(repository)
    try await account().check()
    await drive.remove(repository)
    #expect(try await account().check() == [.backupGone])
    #expect(try store.accountProblems().keys.sorted { $0.rawValue < $1.rawValue } == [.backupGone])
  }

  @Test func noRepositoryYetMeansNothingToLookAt() async throws {
    let fresh = try Store.inMemory()
    let account = DriveAccount(drive: drive, store: fresh)
    try await account.confirmSignedInAccount()
    #expect(try await account.check() == [])
  }

  @Test func theFixesAreListedInTheOrderToTakeThem() async throws {
    await drive.trash(repository)
    await drive.setLimit(1_000)
    #expect(try await account().check() == [.backupInBin, .full])
    await drive.failCalls(to: "about", with: .signedOut)
    #expect(try await account().check() == [.signedOut, .backupInBin, .full])
  }

  // MARK: The network is never a state

  @Test(arguments: [DriveProblem.unreachable, .rateLimited, .dailyUploadLimit])
  func noAnswerFromGoogleSetsNothing(_ problem: DriveProblem) async throws {
    await drive.failCalls(to: "about", with: problem)
    #expect(try await account().check() == [])
    await drive.failCalls(to: "about", with: nil)
    await drive.failCalls(to: "metadata", with: problem)
    #expect(try await account().check() == [])
    #expect(try store.accountProblems().isEmpty)
  }

  @Test func noAnswerFromGoogleLeavesWhatWasKnown() async throws {
    await drive.trash(repository)
    await drive.setLimit(1_000)
    try await account().check()
    await drive.failCalls(to: "about", with: .unreachable)
    #expect(try await account().check() == [.backupInBin, .full])
  }

  // MARK: A failed command

  @Test func aFullDriveMidRunIsFull() async throws {
    #expect(try await account().note(BridgeFailure.drive(.storageFull)) == [.full])
    #expect(try await account().note(DriveProblem.storageFull) == [.full])
  }

  @Test func googleSigningTheUserOutMidRunIsSignedOut() async throws {
    #expect(try await account().note(BridgeFailure.drive(.signedOut)) == [.signedOut])
  }

  @Test func aNotFoundIsTheBackupGoneOnlyWhenTheRepositoryIs() async throws {
    #expect(try await account().note(BridgeFailure.drive(.notFound)) == [])
    await drive.remove(repository)
    #expect(try await account().note(BridgeFailure.drive(.notFound)) == [.backupGone])
  }

  @Test func aNotFoundForATrashedRepositoryIsInTheBin() async throws {
    await drive.trash(repository)
    #expect(try await account().note(DriveProblem.notFound) == [.backupInBin])
  }

  @Test(arguments: [
    BridgeFailure.drive(.unreachable), .drive(.rateLimited), .drive(.dailyUploadLimit),
    .drive(.rejected(status: 400, reason: nil, message: "")),
    .uploadPaused(until: Date(timeIntervalSince1970: 1_800_000_000)),
  ])
  func otherFailuresAreNotTheAccounts(_ failure: BridgeFailure) async throws {
    #expect(try await account().note(failure) == [])
    #expect(try await account().note(CancellationError()) == [])
  }

  // MARK: Put Back

  @Test func putBackTakesTheRepositoryOutOfTheBin() async throws {
    await drive.trash(repository)
    try await account().check()
    try await account().putBack()
    #expect(try store.accountProblems().isEmpty)
    #expect(try await drive.metadata(of: repository).isTrashed == false)
    #expect(try await drive.metadata(of: config).isTrashed == false)
  }

  @Test func putBackTakesAConfigTrashedAloneOutToo() async throws {
    await drive.trash(config)
    try await account().check()
    try await account().putBack()
    #expect(try store.accountProblems().isEmpty)
  }

  @Test func putBackOfABackupEmptiedFromTheBinMeanwhileSaysGone() async throws {
    await drive.trash(repository)
    try await account().check()
    await drive.remove(repository)
    try await account().putBack()
    #expect(try store.accountProblems().keys.sorted { $0.rawValue < $1.rawValue } == [.backupGone])
  }

  // MARK: Kept across launches

  @Test func theProblemsAreInTheDatabaseForTheNextLaunch() async throws {
    let scratch = try Scratch()
    let path = scratch.url.appendingPathComponent("dirbuff.sqlite").path
    do {
      let first = try Store(path: path)
      try first.recordAccountProblem(.signedOut, at: began)
      try first.recordAccountProblem(.full, at: began.addingTimeInterval(60))
    }
    let second = try Store(path: path)
    #expect(
      try second.accountProblems() == [.signedOut: began, .full: began.addingTimeInterval(60)])
    try second.clearAllAccountProblems()
    #expect(try second.accountProblems().isEmpty)
  }
}

extension InMemoryDrive {
  func setLimit(_ limit: Int64?) { limitBytes = limit }
}
