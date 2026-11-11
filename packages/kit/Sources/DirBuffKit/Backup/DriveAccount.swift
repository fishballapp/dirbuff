import Foundation

/// The Google account as Backup depends on it: whether DirBuff may still use it, whether it has
/// room, and whether the backup in it is where DirBuff left it. It finds out at the hourly check
/// and before each run, and when a command fails because of Drive, and keeps what it finds in the
/// database (`Store.accountProblems`) for the states to show. A problem clears when a later look
/// finds its cause gone.
///
/// Only Google's answers set a problem. No answer at all (offline, a dropped connection) leaves
/// every problem as it was: a network failure is never one of these states.
public struct DriveAccount: Sendable {
  /// Drive with less than this free is full (decision 93): a backup stops short of it so it never
  /// stops the user's Gmail.
  public static let roomNeeded: Int64 = 1_000_000_000

  public let drive: any DriveFiles
  let store: Store
  let now: @Sendable () -> Date

  public init(drive: any DriveFiles, store: Store) {
    self.init(drive: drive, store: store, now: { Date() })
  }

  init(drive: any DriveFiles, store: Store, now: @escaping @Sendable () -> Date) {
    self.drive = drive
    self.store = store
    self.now = now
  }

  /// A token refresh and `about.get`, then whether the account is the one this Mac's backup is in
  /// (`settleOwner`), and if it is, a look at the repository in Drive (its folder and its
  /// `config`, each a `files.get`). Returns what is wrong afterwards, the one to fix first at the
  /// front.
  ///
  /// With no account confirmed and no backup made, nothing may be backed up whatever Google
  /// answers, so that is decided first, offline too.
  @discardableResult
  public func check() async throws -> [DriveAccountProblem] {
    if try store.backupOwner() == nil, try store.backupDriveFolders().repository == nil {
      try store.recordAccountProblem(.unconfirmed, at: now())
    }
    do {
      let about = try await drive.about()
      try store.clearAccountProblems([.signedOut])
      if let free = about.freeBytes, free < Self.roomNeeded {
        try store.recordAccountProblem(.full, at: now())
      } else {
        try store.clearAccountProblems([.full])
      }
      if try settleOwner(about) { try await lookAtRepository() }
    } catch let problem as DriveProblem {
      // A problem Backup has no state for, the network's among them, changes nothing.
      _ = try record(problem)
    }
    return try standing()
  }

  /// The cause behind a failed command, if it was the account's, recorded: Google signing the
  /// user out, a full Drive, or a 404 that proves, on a look at the repository, to be the backup
  /// gone. Returns what is wrong afterwards, as `check` does.
  @discardableResult
  public func note(_ error: any Error) async throws -> [DriveAccountProblem] {
    guard let problem = Self.problem(in: error) else { return try standing() }
    do {
      // In an account that isn't the backup's, a 404 says nothing about the backup.
      if try record(problem) == .repository, try !isElsewhere() { try await lookAtRepository() }
    } catch is DriveProblem {
      // The look couldn't be made; the next check makes it.
    }
    return try standing()
  }

  /// **Put Back**: the repository's folder, and any of its `config`, out of Drive's Bin. Looks
  /// again afterwards, so a backup deleted from the Bin meanwhile is told as gone.
  public func putBack() async throws {
    do {
      for id in try repositoryIDs() {
        if try await drive.metadata(of: id).isTrashed { _ = try await drive.untrash(id) }
      }
    } catch DriveProblem.notFound {
      // Emptied from the Bin before it was put back: the look below says so.
    }
    try await check()
  }

  // MARK: What's standing

  private func standing() throws -> [DriveAccountProblem] {
    let problems = try store.accountProblems()
    return DriveAccountProblem.allCases.filter { problems[$0] != nil }
  }

  private enum Reading {
    case recorded
    /// A 404: which of Drive's files is gone isn't known until the repository is looked at.
    case repository
    case nothing
  }

  private func record(_ problem: DriveProblem) throws -> Reading {
    switch problem {
    case .signedOut:
      try store.recordAccountProblem(.signedOut, at: now())
      return .recorded
    case .storageFull:
      try store.recordAccountProblem(.full, at: now())
      return .recorded
    case .notFound:
      return .repository
    case .dailyUploadLimit, .rateLimited, .unreachable, .checksumMismatch, .rejected:
      return .nothing
    }
  }

  /// The Drive problem inside a failure of a command that went through the bridge or `DriveFiles`.
  static func problem(in error: any Error) -> DriveProblem? {
    switch error {
    case BridgeFailure.drive(let problem): problem
    case let problem as DriveProblem: problem
    default: nil
    }
  }

  // MARK: The repository

  /// The repository's folder, and its `config` as the bridge's table knows it (a name can be
  /// there twice).
  private func repositoryIDs() throws -> [DriveFileID] {
    guard let repository = try store.backupDriveFolders().repository else { return [] }
    return [repository]
      + (try store.repositoryFiles(in: repository, at: RepositoryLayout.config).map(\.driveID))
  }

  /// Whether the backup is where DirBuff left it: its folder not deleted or in the Bin, and its
  /// `config`, which every restic command opens first, in the folder still. Nothing is known of a
  /// repository not yet made, nor of its `config` before the bridge has written or listed it.
  private func lookAtRepository() async throws {
    guard let repository = try store.backupDriveFolders().repository else {
      try store.clearAccountProblems([.backupGone, .backupInBin])
      return
    }
    switch try await state(of: [repository]) {
    case .gone: return try markBackup(.backupGone)
    case .inBin: return try markBackup(.backupInBin)
    case .there: break
    }
    let configs = try store.repositoryFiles(in: repository, at: RepositoryLayout.config)
      .map(\.driveID)
    guard !configs.isEmpty else { return try markBackup(nil) }
    // A second copy of `config` is as good as the first.
    switch try await state(of: configs, allOf: false) {
    case .gone: try markBackup(.backupGone)
    case .inBin: try markBackup(.backupInBin)
    case .there: try markBackup(nil)
    }
  }

  private enum Where { case there, inBin, gone }

  /// Where the files are: `there` if every one is (or, with `allOf` false, any one is), else in
  /// the Bin if any is, else gone.
  private func state(of ids: [DriveFileID], allOf: Bool = true) async throws -> Where {
    var places: [Where] = []
    for id in ids {
      do {
        places.append(try await drive.metadata(of: id).isTrashed ? .inBin : .there)
      } catch DriveProblem.notFound {
        places.append(.gone)
      }
    }
    if allOf ? places.allSatisfy({ $0 == .there }) : places.contains(.there) { return .there }
    return places.contains(.inBin) ? .inBin : .gone
  }

  /// The backup is gone or in the Bin (the other is cleared), or neither.
  private func markBackup(_ problem: DriveAccountProblem?) throws {
    let backupProblems: [DriveAccountProblem] = [.backupGone, .backupInBin]
    try store.clearAccountProblems(backupProblems.filter { $0 != problem })
    if let problem { try store.recordAccountProblem(problem, at: now()) }
  }
}
