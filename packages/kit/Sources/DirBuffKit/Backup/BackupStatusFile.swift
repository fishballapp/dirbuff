import DirBuffCore
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
  /// When this file was written. While a backup runs it is rewritten about once a minute, as long
  /// as the backup moves (`BackupStatusWriter`).
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
    /// How far the running backup has got; absent when none runs, and until restic has reported.
    public var progress: Progress?
    /// Why the last run failed; absent once one succeeds.
    public var lastError: String?
    public var failingSince: Date?
    public var failedRunsInARow: Int
    /// How many files the last backup couldn't read.
    public var unreadFileCount: Int
    /// Newest first.
    public var attempts: [Attempt]

    public init(
      path: String, status: BackupStatus, attempts: [BackupAttempt], progress: Progress? = nil,
      now: Date
    ) {
      let running = attempts.first { $0.outcome == .running }
      self.path = path
      self.progress = running == nil ? nil : progress
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

  /// How far a running backup has got: restic's own running count, the one the app's progress
  /// line shows.
  public struct Progress: Codable, Equatable, Sendable {
    public var filesDone: Int
    /// Absent until restic has counted the folder.
    public var filesTotal: Int?
    public var bytesDone: Int64
    /// Absent until restic has counted the folder.
    public var bytesTotal: Int64?
    /// When the count last changed, which is how a reader tells a backup that is moving from one
    /// that has stalled. Up to a minute older than the truth: the file is written no oftener.
    public var movedAt: Date

    init(_ progress: RunProgress, movedAt: Date) {
      filesDone = progress.itemsDone
      filesTotal = progress.itemsTotal == 0 ? nil : progress.itemsTotal
      bytesDone = progress.bytesDone
      bytesTotal = progress.bytesTotal == 0 ? nil : progress.bytesTotal
      self.movedAt = movedAt
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
  /// Every Backup folder as the status file tells it, from the database and the progress of the
  /// backups running now (by folder).
  public func statusFile(
    now: Date = Date(), progress: [Int64: BackupStatusFile.Progress] = [:]
  ) throws -> BackupStatusFile {
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
        progress: progress[wear.folderID], now: now)
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

// MARK: - Writing it

/// Keeps `backup-status.json` true while backups run: every write goes through here, one at a
/// time, so a progress write can't land after the write that says the backup ended.
///
/// A running backup rewrites the file when what it would say has changed (the counts, the totals
/// or `movedAt`), and no oftener than `progressInterval` after the last write of any kind. A
/// backup that has stopped moving writes nothing: the file's `progress.movedAt` stops there, and
/// a Mac's disk isn't woken for it. `movedAt` moves only when files done or bytes done do.
public actor BackupStatusWriter {
  /// About once a minute: finer than the half hour restic is given to stand still, and a few
  /// hundred small writes over the longest first backup, made while it uploads anyway.
  public static let progressInterval: TimeInterval = 60

  private struct Running {
    /// The newest report, so the totals written are current.
    var latest: RunProgress?
    /// When files done or bytes done last changed: the totals restic keeps raising while it
    /// counts, and the item it is on, are not getting further.
    var movedAt: Date?
    /// What the file last said, to write only when what it would say has changed.
    var written: BackupStatusFile.Progress?

    var file: BackupStatusFile.Progress? {
      latest.flatMap { latest in movedAt.map { BackupStatusFile.Progress(latest, movedAt: $0) } }
    }
  }

  private let backup: BackupBuff
  private let url: URL
  private let now: @Sendable () -> Date
  private var running: [Int64: Running] = [:]
  private var lastWriteAt: Date?

  public init(backup: BackupBuff, url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.backup = backup
    self.url = url
    self.now = now
  }

  /// Rewrites the file from the database and the progress of the backups running now: for
  /// anything that changed what it says (a check, the account, the folders, DirBuff starting).
  public func write() throws {
    let at = now()
    // The attempt is stamped before the write, so a disk that fails is tried again after the
    // interval, not at every report.
    lastWriteAt = at
    let progress = running.compactMapValues(\.file)
    try backup.statusFile(now: at, progress: progress).write(to: url)
    running = running.mapValues {
      Running(latest: $0.latest, movedAt: $0.movedAt, written: $0.file)
    }
  }

  /// A backup of the folder has started, and the file says so at once.
  public func backupBegan(folderID: Int64) throws {
    running[folderID] = Running()
    try write()
  }

  /// A report of how far the running backup has got, which is restic's every second; a report
  /// for a folder that isn't running (one that arrives late) is dropped.
  public func report(_ progress: RunProgress) throws {
    guard var run = running[progress.folderID] else { return }
    let at = now()
    if run.latest?.itemsDone != progress.itemsDone || run.latest?.bytesDone != progress.bytesDone {
      run.movedAt = at
    }
    run.latest = progress
    running[progress.folderID] = run
    guard run.file != run.written,
      at.timeIntervalSince(lastWriteAt ?? .distantPast) >= Self.progressInterval
    else { return }
    try write()
  }

  /// The backup of the folder is over, however it ended (the database already says how): the
  /// file says so at once.
  public func backupEnded(folderID: Int64) throws {
    running[folderID] = nil
    try write()
  }
}
