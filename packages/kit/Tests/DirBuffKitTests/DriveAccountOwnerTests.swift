import Foundation
import Testing

@testable import DirBuffKit

/// Which Google account this Mac's backup lives in: remembered once the user confirms it (or, for
/// a backup made before DirBuff remembered it, whoever is signed in next), so signing in as
/// someone else never reads as the backup being gone, and nothing is backed up before the user
/// has said which account to use.
@Suite struct DriveAccountOwnerTests {
  /// Jo's Drive, which holds this Mac's repository.
  let jo = InMemoryDrive(email: "jo@example.com", pageSize: 100)
  /// Sam's Drive: another account, where Jo's files can't be seen.
  let sam = InMemoryDrive(email: "sam@example.com", pageSize: 100)
  let store: Store
  let began = Date(timeIntervalSince1970: 1_800_000_000)

  init() throws {
    store = try Store.inMemory()
  }

  func account(_ drive: InMemoryDrive) -> DriveAccount {
    DriveAccount(drive: drive, store: store, now: { [began] in began })
  }

  /// This Mac's repository in Jo's Drive, as a backup made it.
  func makeRepositoryInJosDrive() async throws {
    let backups = try await jo.createFolder(named: "DirBuff Backup", in: nil)
    let repository = try await jo.createFolder(named: "Test Mac", in: backups.id).id
    let config = try await jo.upload(Data("config".utf8), named: "config", in: repository).id
    try store.saveBackupDriveRepository(repository)
    try store.record(RepositoryFile(path: "config", driveID: config, size: 6), in: repository)
  }

  // MARK: Before the user confirms

  @Test func aFirstSignInBacksNothingUpUntilConfirmed() async throws {
    #expect(try account(jo).isAwaitingConfirmation())
    #expect(try await account(jo).check() == [.unconfirmed])
    #expect(try store.backupOwner() == nil)
    try await account(jo).confirmSignedInAccount()
    #expect(try !account(jo).isAwaitingConfirmation())
  }

  @Test func offlineAFirstSignInIsStillUnconfirmed() async throws {
    await jo.failCalls(to: "about", with: .unreachable)
    #expect(try await account(jo).check() == [.unconfirmed])
  }

  @Test func confirmingRemembersTheAccount() async throws {
    try await account(jo).check()
    let owner = try await account(jo).confirmSignedInAccount()
    #expect(owner == BackupOwner(accountID: "id-jo@example.com", email: "jo@example.com"))
    #expect(try store.backupOwner() == owner)
    #expect(try await account(jo).check() == [])
  }

  @Test func withNoBackupYetAnotherAccountIsConfirmedAfresh() async throws {
    try await account(jo).confirmSignedInAccount()
    // Nothing was backed up to Jo's Drive, so there is nothing of Jo's to keep.
    #expect(try await account(sam).check() == [.unconfirmed])
    try await account(sam).confirmSignedInAccount()
    #expect(try store.backupOwner()?.email == "sam@example.com")
    #expect(try await account(sam).check() == [])
  }

  // MARK: A backup that exists

  @Test func aBackupMadeBeforeDirBuffRememberedAdoptsWhoeverIsSignedIn() async throws {
    try await makeRepositoryInJosDrive()
    #expect(try await account(jo).check() == [])
    #expect(try store.backupOwner()?.email == "jo@example.com")
  }

  @Test func anotherAccountIsNotABackupGone() async throws {
    try await makeRepositoryInJosDrive()
    try await account(jo).check()
    #expect(try await account(sam).check() == [.otherAccount])
    #expect(try store.accountProblems()[.backupGone] == nil)
    // A command's 404 in Sam's Drive is no proof either.
    try await account(sam).note(DriveProblem.notFound)
    #expect(try store.accountProblems()[.backupGone] == nil)
  }

  @Test func anotherAccountCantBeConfirmedOverTheBackup() async throws {
    try await makeRepositoryInJosDrive()
    try await account(jo).check()
    await #expect(throws: DriveAccount.Failure.backupInAnotherAccount) {
      try await account(sam).confirmSignedInAccount()
    }
    #expect(try store.backupOwner()?.email == "jo@example.com")
  }

  @Test func signingBackInAsTheOwnerClearsIt() async throws {
    try await makeRepositoryInJosDrive()
    try await account(jo).check()
    try await account(sam).check()
    #expect(try await account(jo).check() == [])
  }

  @Test func startingANewBackupInTheOtherAccountMakesItTheOwner() async throws {
    try await makeRepositoryInJosDrive()
    try await account(jo).check()
    try await account(sam).check()
    try store.startAgainBackupRepository(
      repository: "new", host: "Test Mac", now: began,
      owner: BackupOwner(accountID: "id-sam@example.com", email: "sam@example.com"))
    #expect(try store.backupOwner()?.email == "sam@example.com")
    #expect(try store.accountProblems()[.otherAccount] == nil)
  }

  @Test func signingOutForgetsNothingOfTheOwner() async throws {
    try await makeRepositoryInJosDrive()
    try await account(jo).check()
    try store.clearAllAccountProblems()
    #expect(try store.backupOwner()?.email == "jo@example.com")
  }

  @Test func googlesPermissionIDTellsAccountsApart() throws {
    let reply = Data(
      #"{"user":{"emailAddress":"jo@example.com","permissionId":"0123"},"storageQuota":{"usage":"5"}}"#
        .utf8)
    let about = try JSONDecoder().decode(DriveAbout.self, from: reply)
    #expect(about.permissionID == "0123")
    #expect(about.accountID == "0123")
  }
}
