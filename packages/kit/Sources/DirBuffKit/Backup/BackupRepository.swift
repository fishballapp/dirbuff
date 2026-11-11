import Foundation

/// Where the Macs' backups are kept, one restic repository per Mac, and which of them is this
/// Mac's.
public protocol BackupStorage: Sendable {
  /// This Mac's repository: found or made the first time, and remembered after, so it keeps
  /// working wherever it's moved.
  func thisMac() async throws -> any BackupRepository
  /// Every Mac's repository kept here, this Mac's among them.
  func macs() async throws -> [BackedUpMac]
  /// One Mac's repository, listed afresh, for reading. It becomes this Mac's when the database
  /// names `mac.id` as this Mac's repository.
  func repository(of mac: BackedUpMac) async throws -> any BackupRepository

  /// Before a command that uses the storage for a backup: throws
  /// `BackupBuff.Failure.accountProblem` if what the storage lives in can't be used, with the
  /// reason kept for the states to show. Not being able to find out (offline) is no problem.
  func confirmUsable() async throws
  /// After a command on the storage failed, in case the account was why: keeps its reason.
  func noteFailure(_ error: any Error) async
  /// A new, empty repository beside this Mac's, which the database doesn't know yet: `id` is
  /// what it will name as this Mac's, as `BackedUpMac.id` does. Nothing is deleted.
  func makeNewRepository() async throws -> (id: String, repository: any BackupRepository)
}

extension BackupStorage {
  public func confirmUsable() async throws {}
  public func noteFailure(_ error: any Error) async {}
  public func makeNewRepository() async throws -> (id: String, repository: any BackupRepository) {
    throw BackupBuff.Failure.cannotStartAgain
  }
}

/// One Mac's repository.
public protocol BackupRepository: Sendable {
  /// Runs one restic command against the repository: `body` is given `restic` pointed at it,
  /// valid until `body` returns. A bridge to a remote store starts for each command and stops
  /// after it, so none outlives a run.
  func serving<Result>(_ restic: Restic, _ body: (Restic) async throws -> Result) async throws
    -> Result
  /// Makes what restic is shown match what the store holds now, not what was last written to
  /// it, and returns the files (by their path in the repository) that were written and are gone.
  /// Locks aren't among them.
  @discardableResult
  func refreshListing() async throws -> [String]
}

/// A Mac's repository, as Restore from Google Drive lists them.
public struct BackedUpMac: Sendable, Hashable {
  /// Where the storage finds it: a Drive folder's ID, or a folder's path.
  public var id: String
  /// The computer's name when Backup first went on there, or what the user renamed it to.
  public var name: String
  public var isThisMac: Bool

  public init(id: String, name: String, isThisMac: Bool) {
    self.id = id
    self.name = name
    self.isThisMac = isThisMac
  }
}

/// One repository in a folder on this Mac, laid out as restic lays out any local repository.
/// It holds only this Mac's backup: it's for tests and for trying Backup without an account.
public struct LocalRepository: BackupStorage, BackupRepository {
  public let folder: URL

  public init(folder: URL) {
    self.folder = folder
  }

  public enum Failure: Error, Equatable {
    /// A local repository is one Mac's, and can't become another's.
    case otherMac
  }

  // MARK: BackupStorage

  public func thisMac() async throws -> any BackupRepository { self }

  public func macs() async throws -> [BackedUpMac] {
    guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("config").path)
    else { return [] }
    return [BackedUpMac(id: folder.path, name: folder.lastPathComponent, isThisMac: true)]
  }

  public func repository(of mac: BackedUpMac) async throws -> any BackupRepository {
    guard mac.id == folder.path else { throw Failure.otherMac }
    return self
  }

  // MARK: BackupRepository

  public func serving<Result>(_ restic: Restic, _ body: (Restic) async throws -> Result)
    async throws -> Result
  {
    var restic = restic
    restic.repository = folder.path
    return try await body(restic)
  }

  /// restic lists the folder itself.
  public func refreshListing() async throws -> [String] { [] }
}
