import Foundation

/// `backup-status.json`: what Backup is doing, for a watchdog outside DirBuff to read. Its format
/// is kept: a field is never removed or changed in meaning without a new `version`.
///
/// A key with no value is left out.
public struct BackupStatusFile: Codable, Equatable, Sendable {
  /// The format's version: changes only when a field is removed or means something else. A new
  /// field doesn't change it.
  public static let currentVersion = 1
  public static let fileName = "backup-status.json"
  /// How many attempts a folder lists.
  public static let attemptLimit = 10

  public var version: Int
  /// When this file was written; a file that stops changing means DirBuff isn't running.
  public var writtenAt: Date
  /// The last weekly check that ran to its end; absent before the first.
  public var check: Check?
  /// What stops Backup using the Google account, when something does; absent otherwise.
  public var account: Account?
  /// Every folder that wears Backup.
  public var folders: [Folder]

  public init(writtenAt: Date, check: Check?, account: Account? = nil, folders: [Folder]) {
    version = Self.currentVersion
    self.writtenAt = writtenAt
    self.check = check
    self.account = account
    self.folders = folders
  }

  /// A problem with the account every folder shares. No backup runs while one stands, so none
  /// fails either: this is how a reader outside DirBuff learns why nothing is being backed up.
  public struct Account: Codable, Equatable, Sendable {
    public var problem: Problem
    public var since: Date

    public init(problem: Problem, since: Date) {
      self.problem = problem
      self.since = since
    }

    public enum Problem: String, Codable, Equatable, Sendable {
      /// Google no longer accepts DirBuff's access; the user has to sign in again.
      case signedOut
      /// Signed in to a Google account that isn't the one this Mac's backup is in.
      case otherAccount
      /// Signed in, but the user hasn't confirmed the account yet: nothing is backed up until
      /// they do.
      case unconfirmed
      /// Google Drive is full or within 1 GB of it.
      case driveFull
      /// The backup was deleted in Google Drive.
      case backupGone
      /// The backup is in Google Drive's Bin.
      case backupInBin

      init(_ problem: DriveAccountProblem) {
        switch problem {
        case .signedOut: self = .signedOut
        case .otherAccount: self = .otherAccount
        case .unconfirmed: self = .unconfirmed
        case .full: self = .driveFull
        case .backupGone: self = .backupGone
        case .backupInBin: self = .backupInBin
        }
      }
    }
  }

  public struct Check: Codable, Equatable, Sendable {
    public var checkedAt: Date
    public var isWhole: Bool
    /// What's missing or damaged, in words; absent when the backup is whole.
    public var problem: String?

    public init(_ check: BackupCheck) {
      checkedAt = check.checkedAt
      isWhole = check.isWhole
      problem = check.problem
    }
  }

  /// A folder's own record, which the account's state isn't part of: signed out of Google, the
  /// runs simply fail, and the folder says `failing` after three.
  public enum State: String, Codable, Equatable, Sendable {
    /// A backup is running now.
    case running
    /// Three runs in a row failed, or every run has for three hours.
    case failing
    /// No backup has finished yet.
    case neverBackedUp
    /// The last good backup is three days old or more.
    case stale
    /// The last backup saved, with files it couldn't read.
    case filesUnread
    case upToDate
  }

  public struct Folder: Codable, Equatable, Sendable {
    /// Where DirBuff last found it.
    public var path: String
    public var state: State
    /// When it last ran, or went on Backup.
    public var lastRunAt: Date
    public var lastSuccessAt: Date?
    /// Since when a backup is running; absent otherwise.
    public var runningSince: Date?
    /// Why the last run failed; absent once one succeeds.
    public var lastError: String?
    public var failingSince: Date?
    public var failedRunsInARow: Int
    /// How many files the last backup couldn't read.
    public var unreadFileCount: Int
    /// Newest first.
    public var attempts: [Attempt]

    public init(path: String, status: BackupStatus, attempts: [BackupAttempt], now: Date) {
      let running = attempts.first { $0.outcome == .running }
      self.path = path
      lastRunAt = status.lastRunAt
      lastSuccessAt = status.lastSuccessAt
      runningSince = running?.startedAt
      lastError = status.lastError
      failingSince = status.failingSince
      failedRunsInARow = status.failedRunsInARow
      unreadFileCount = status.skipped.count
      self.attempts = attempts.prefix(BackupStatusFile.attemptLimit).map(Attempt.init)
      state =
        if running != nil {
          .running
        } else if status.isFailing(now: now) {
          .failing
        } else if status.lastSuccessAt == nil {
          .neverBackedUp
        } else if status.isStale(now: now) {
          .stale
        } else if !status.skipped.isEmpty {
          .filesUnread
        } else {
          .upToDate
        }
    }
  }

  public struct Attempt: Codable, Equatable, Sendable {
    public var startedAt: Date
    /// Absent while it runs.
    public var endedAt: Date?
    public var outcome: BackupAttempt.Outcome
    /// The snapshot a saved attempt made.
    public var snapshotID: String?
    public var filesNew: Int
    public var filesChanged: Int
    public var bytesAdded: Int64
    /// Files that attempt couldn't read.
    public var skippedCount: Int
    public var error: String?

    init(_ attempt: BackupAttempt) {
      startedAt = attempt.startedAt
      endedAt = attempt.endedAt
      outcome = attempt.outcome
      snapshotID = attempt.snapshotID
      filesNew = attempt.filesNew
      filesChanged = attempt.filesChanged
      bytesAdded = attempt.bytesAdded
      skippedCount = attempt.skippedCount
      error = attempt.error
    }
  }

  // MARK: - On disk

  /// The file as it is written: keys sorted, dates in ISO 8601 UTC.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }

  public static func decoded(from data: Data) throws -> BackupStatusFile {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(BackupStatusFile.self, from: data)
  }

  /// Replaces the file at `url` whole: a reader sees the old file or the new, never half of one.
  public func write(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoded().write(to: url, options: .atomic)
  }
}

extension BackupBuff {
  /// Every Backup folder as the status file tells it, from the database alone.
  public func statusFile(now: Date = Date()) throws -> BackupStatusFile {
    let folders = try store.backupWearers().compactMap { wear -> BackupStatusFile.Folder? in
      // A folder removed from DirBuff takes its Backup with it.
      guard let folder = try store.folder(id: wear.folderID),
        let record = try store.backupRecord(folderID: wear.folderID)
      else { return nil }
      let status = BackupStatus(
        lastRunAt: record.lastRunAt, lastSuccessAt: record.lastSuccessAt,
        lastError: record.lastError, failingSince: record.failingSince,
        failedRunsInARow: record.failedRunsInARow,
        skipped: try store.backupSkipped(folderID: wear.folderID), leftOut: [],
        cloudOnlyCount: record.cloudOnlyCount)
      return BackupStatusFile.Folder(
        path: folder.path, status: status,
        attempts: try store.backupAttempts(
          folderID: wear.folderID, limit: BackupStatusFile.attemptLimit),
        now: now)
    }
    let problems = try store.accountProblems()
    let account = DriveAccountProblem.allCases.lazy.compactMap { problem in
      problems[problem].map {
        BackupStatusFile.Account(problem: .init(problem), since: $0)
      }
    }.first
    return BackupStatusFile(
      writtenAt: now, check: try lastCheck().map(BackupStatusFile.Check.init), account: account,
      folders: folders)
  }
}
