import DirBuffCore
import Foundation
import os

/// Backup: saves a folder's files into the Mac's one restic repository, as a series of snapshots
/// of its own, and thins its history with age. It never changes the folder.
///
/// One restic command runs at a time per Mac, so a backup, a forget, a prune and a key change
/// never wait on each other's lock.
public struct BackupBuff: BuffModule {
  public let engine: Engine
  public let repository: any BackupRepository
  public let keychain: any BackupKeychain
  private let executable: URL
  /// restic's cache of the repository's index.
  private let cacheDirectory: URL
  /// Whose `Library` a backup of their home leaves out.
  private let home: URL
  /// Folders of DirBuff's own that a backup leaves out wherever they are: the cache, and a
  /// repository on this Mac.
  private let ownFolders: [URL]
  private let qualityOfService: QualityOfService
  private let commands = OneAtATime()
  private var store: Store { engine.store }
  private static let logger = Logger(subsystem: "app.fishball.dirbuff", category: "backup")

  /// How often `maintain` prunes the repository.
  public static let pruneInterval: TimeInterval = 7 * 86_400
  /// `prune` and `check` can go quiet for long stretches, so they have a limit on the clock.
  public static let pruneLimit = Duration.seconds(4 * 3_600)

  public init(
    engine: Engine, repository: any BackupRepository,
    keychain: any BackupKeychain = LoginKeychain(),
    executable: URL = Restic.bundledExecutable, cacheDirectory: URL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    ownFolders: [URL] = [], qualityOfService: QualityOfService = Restic.defaultQualityOfService
  ) {
    self.engine = engine
    self.repository = repository
    self.keychain = keychain
    self.executable = executable
    self.cacheDirectory = cacheDirectory
    self.home = home
    self.ownFolders = [cacheDirectory] + ownFolders
    self.qualityOfService = qualityOfService
  }

  public enum Failure: Error, Equatable {
    /// The repository's key is in neither the Keychain nor the repository: Private Backup is on
    /// and this Mac lost its copy. Only the recovery key opens the backup now.
    case keyMissing
    /// A name to leave out can't hold a `/`; that's a path.
    case nameWithSlash(String)
    /// The recovery key typed back isn't one `makeRecoveryKey` made: nothing was changed.
    case recoveryKeyDoesNotOpen
  }

  public var buff: Buff { .backup }
  public var schedule: BuffSchedule {
    .afterChange(settle: .seconds(300), spacing: .seconds(3_600), check: .seconds(3_600))
  }
  public var defaultSettings: BackupSettings { BackupSettings() }

  /// Any folder can be backed up; Home leaves out its `Library` instead.
  public func refusal(for url: URL) -> Refusal? { nil }

  public func wear(folderID: Int64) throws -> Wear<BackupSettings>? {
    try store.backupWear(folderID: folderID)
  }

  public func wearers() throws -> [Wear<BackupSettings>] {
    try store.backupWearers()
  }

  public func putOn(folderID: Int64, now: Date = Date()) throws {
    try store.putOnBackup(folderID: folderID, settings: defaultSettings, now: now)
  }

  /// A shorter history takes effect at the folder's next forget.
  public func save(_ settings: BackupSettings, folderID: Int64, now: Date = Date()) throws {
    try store.saveBackupSettings(settings, folderID: folderID)
  }

  /// Forgets the settings and keeps the backup in the repository.
  public func takeOff(folderID: Int64) throws {
    try takeOff(folderID: folderID, isDeletingBackup: false)
  }

  /// Forgets the settings at once. With `isDeletingBackup` ("Also delete its backup"), the
  /// folder's snapshots go from the repository at the next `maintain`, which retries until they
  /// have.
  public func takeOff(folderID: Int64, isDeletingBackup: Bool) throws {
    try store.takeOffBackup(folderID: folderID, isDeletingBackup: isDeletingBackup)
  }

  public func setPausedByLicence(_ isPaused: Bool, folderID: Int64) throws {
    try store.setBackupPausedByLicence(isPaused, folderID: folderID)
  }

  /// From the database alone: nothing on the Mac or in the repository is read.
  public func read(_ folder: LocatedFolder, _ wear: Wear<BackupSettings>, now: Date = Date())
    throws -> BackupStatus
  {
    let folderID = wear.folderID
    guard let record = try store.backupRecord(folderID: folderID) else {
      return BackupStatus(
        lastRunAt: wear.lastRunAt, lastSuccessAt: nil, lastError: nil, failingSince: nil,
        failedRunsInARow: 0, skipped: [], leftOut: [], cloudOnlyCount: 0)
    }
    return BackupStatus(
      lastRunAt: record.lastRunAt,
      lastSuccessAt: record.lastSuccessAt,
      lastError: record.lastError,
      failingSince: record.failingSince,
      failedRunsInARow: record.failedRunsInARow,
      skipped: try store.backupSkipped(folderID: folderID),
      leftOut: try store.backupLeftOut(folderID: folderID),
      cloudOnlyCount: record.cloudOnlyCount)
  }

  // MARK: - Run

  /// Saves the folder as one snapshot, records what changed for its Versions page, and the run
  /// for History. A folder the licence paused isn't backed up. Its history is thinned by
  /// `maintain`, not here.
  public func run(
    _ folder: LocatedFolder, _ wear: Wear<BackupSettings>, context: RunContext
  ) async throws -> RunSummary {
    guard !wear.isPausedByLicence else { return RunSummary(items: 0, bytes: 0, failures: 0) }
    return try await commands.run {
      try await backUp(folder, folderID: wear.folderID, context: context)
    }
  }

  private func backUp(_ folder: LocatedFolder, folderID: Int64, context: RunContext) async throws
    -> RunSummary
  {
    let now = context.scheduledAt
    // Taken off while it waited for the run before it.
    guard let record = try store.backupRecord(folderID: folderID) else {
      return RunSummary(items: 0, bytes: 0, failures: 0)
    }
    // Every write names the series this run backs up, so a run that outlives it (Backup taken
    // off, and maybe put on again, meanwhile) records nothing over the new one.
    try store.recordBackupStarted(record, at: now)
    do {
      let session = try await openRepository(now: now)
      let root = try canonicalPath(of: folder.url)
      let exclusions = await Self.scan(
        root, leftOut: try store.backupLeftOut(folderID: folderID),
        home: try canonicalPath(of: home), own: ownFolders.compactMap { try? canonicalPath(of: $0) }
      )
      let result = try await restic(session) { restic in
        try await restic.backup(
          URL(fileURLWithPath: root), tags: [record.resticTag], host: session.host,
          excluding: exclusions.patterns, excludingCaches: true,
          onProgress: { context.progress(RunProgress(folderID: folderID, $0)) })
      }
      guard let snapshotID = result.summary.snapshotId else {
        throw ResticFailure.unusable("restic saved no snapshot")
      }
      let saved = SavedBackup(
        snapshotID: snapshotID,
        savedAt: result.summary.backupStart ?? now,
        filesNew: Int(result.summary.filesNew),
        filesChanged: Int(result.summary.filesChanged),
        bytesAdded: Int64(result.summary.dataAdded),
        skipped: result.unreadable.map {
          SkippedFile(path: inside(root, $0.item), reason: $0.message)
        },
        versions: try await versions(
          from: record.lastSnapshotID, to: snapshotID, in: root, session: session),
        cloudOnlyCount: exclusions.cloudOnlyCount)
      try store.recordBackup(saved, for: record, runID: context.runID, at: Date())
      Self.logger.info(
        "Saved \(snapshotID, privacy: .public): \(saved.filesNew) new, \(saved.filesChanged) changed, \(saved.skipped.count) skipped"
      )
      return RunSummary(
        items: saved.filesNew + saved.filesChanged, bytes: saved.bytesAdded,
        failures: saved.skipped.count)
    } catch {
      do {
        try store.recordBackupFailure(
          String(describing: error), for: record, runID: context.runID, at: Date())
      } catch let recording {
        Self.logger.error(
          "Couldn't record a failed backup: \(String(describing: recording), privacy: .public)")
      }
      throw error
    }
  }

  /// The walk reads every file's attributes, seconds on a big folder, so it runs off the threads
  /// Swift's tasks share.
  private static func scan(_ root: String, leftOut: [LeaveOut], home: String, own: [String]) async
    -> Exclusions
  {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(
          returning: Exclusions.scan(root, leftOut: leftOut, home: home, own: own))
      }
    }
  }

  /// What changed from the folder's last snapshot to this one, file by file. The first snapshot
  /// has nothing before it: every file in it is the one version there is.
  private func versions(
    from previous: String?, to snapshotID: String, in root: String, session: Session
  ) async throws -> [SavedVersion] {
    guard let previous else { return [] }
    let changes: [DiffChange]
    do {
      changes = try await restic(session) { try await $0.diff(from: previous, to: snapshotID) }
    } catch {
      // ponytail: the snapshot is saved whatever the diff does, so a failed diff costs only this
      // run's lines on the Versions page, not the backup. Un-park if it's ever seen in the log.
      Self.logger.error(
        "Couldn't list what changed: \(String(describing: error), privacy: .public)")
      return []
    }
    return changes.compactMap { change in
      let path = String(change.path.drop { $0 == "/" }.dropLast(change.isFolder ? 1 : 0))
      // A folder is no version of anything, but one that took a file's place ends that file's
      // life on this Mac. (restic doesn't list what's in the new folder.)
      guard !change.isFolder || change.modifier == .typeChanged else { return nil }
      if change.isFolder { return SavedVersion(path: path, change: .removed, size: nil) }
      let size = {
        try? FileManager.default.attributesOfItem(atPath: root + "/" + path)[.size] as? Int64
      }
      switch change.modifier {
      case .added: return SavedVersion(path: path, change: .added, size: size())
      case .modified, .typeChanged: return SavedVersion(path: path, change: .changed, size: size())
      case .removed: return SavedVersion(path: path, change: .removed, size: nil)
      case .metadataChanged, .unknown: return nil
      }
    }
  }

  /// A path restic reported, as a path inside the folder.
  private func inside(_ root: String, _ path: String) -> String {
    if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
    if path.hasPrefix("./") { return String(path.dropFirst(2)) }
    return path
  }

  // MARK: - Maintenance

  /// Thins each Backup folder's history once a day, deletes the backups of folders Backup came
  /// off with "also delete its backup", and prunes the data none of it uses any more once a week.
  public func maintain(now: Date = Date(), calendar: Calendar = .current) async throws {
    try await commands.run {
      // Nothing was ever backed up on this Mac.
      guard let account = try store.backupAccount() else { return }
      let session = try await openRepository(now: now)
      for wear in try store.backupWearers() where !wear.isPausedByLicence {
        guard let record = try store.backupRecord(folderID: wear.folderID),
          record.lastSuccessAt != nil,
          record.lastForgetAt.map({ !calendar.isDate($0, inSameDayAs: now) }) ?? true
        else { continue }
        try await forget(record, session: session, now: now)
      }
      let deletions = try store.pendingBackupDeletions()
      for tag in deletions {
        let snapshots = try await restic(session) {
          try await $0.snapshots(tags: [BackupRecord.resticTag(tag)], host: session.host)
        }
        try await restic(session) { try await $0.forget(snapshotIDs: snapshots.map(\.id)) }
      }
      let isPruneDue =
        now.timeIntervalSince(account.lastPrunedAt ?? account.createdAt) >= Self.pruneInterval
      guard !deletions.isEmpty || isPruneDue else { return }
      try await prune(session)
      try store.recordPrune(at: now)
      try store.finishBackupDeletions(deletions)
    }
  }

  /// Removes the snapshots the folder's history no longer keeps, and their versions.
  private func forget(_ record: BackupRecord, session: Session, now: Date) async throws {
    let groups = try await restic(session) {
      try await $0.forget(
        keeping: Self.policy(record.history), tags: [record.resticTag], host: session.host)
    }
    try store.recordForget(folderID: record.folderID, kept: groups.flatMap(\.keep), at: now)
  }

  private func prune(_ session: Session) async throws {
    try await restic(session) {
      try await $0.prune(maxUnused: "10%", maxRepackSize: "1G", wallClockLimit: Self.pruneLimit)
    }
  }

  /// The latest 10, then the newest of each hour for 48 hours, each day for 30 days, each week for
  /// 12 weeks, each month for 24 months (or a year), and each year for ever; the shorter
  /// histories stop early.
  static func policy(_ history: BackupHistory) -> ForgetPolicy {
    let recent = ForgetPolicy(
      last: 10, withinHourly: .hours(48), withinDaily: .days(30))
    switch history {
    case .forever:
      var policy = recent
      policy.withinWeekly = .days(84)
      policy.withinMonthly = .months(24)
      policy.yearly = .unlimited
      return policy
    case .oneYear:
      var policy = recent
      policy.withinWeekly = .days(84)
      policy.withinMonthly = .years(1)
      return policy
    case .thirtyDays:
      return recent
    }
  }

  // MARK: - Leave Out

  public func leftOut(folderID: Int64) throws -> [LeaveOut] {
    try store.backupLeftOut(folderID: folderID)
  }

  /// Leaves a path or a name out of the folder's next backups. What it covers stops counting as
  /// skipped at once.
  public func leaveOut(_ item: LeaveOut, folderID: Int64) throws {
    if case .name(let name) = item, name.contains("/") { throw Failure.nameWithSlash(name) }
    try store.leaveOut(Self.normalised(item), folderID: folderID)
  }

  public func bringBack(_ item: LeaveOut, folderID: Int64) throws {
    try store.bringBack(Self.normalised(item), folderID: folderID)
  }

  private static func normalised(_ item: LeaveOut) -> LeaveOut {
    guard case .path(let path) = item else { return item }
    return .path(path.split(separator: "/").joined(separator: "/"))
  }

  // MARK: - The key

  public func keyCustody() throws -> KeyCustody? {
    try store.backupAccount()?.keyCustody
  }

  /// Private Backup, first step: makes a recovery key and adds it to the repository, beside the
  /// key that opens it now. Nothing that opens the backup goes: `password.txt`, the Keychain and
  /// the old key stay as they were, so a user who never confirms the key loses nothing.
  public func makeRecoveryKey(now: Date = Date()) async throws -> String {
    try await commands.run {
      let session = try await openRepository(now: now)
      let recoveryKey = RecoveryKey.make()
      _ = try await restic(session) { try await $0.addKey(newPassword: recoveryKey) }
      return recoveryKey
    }
  }

  /// Private Backup, second step, once the user has typed the recovery key back: checks it opens
  /// the repository, keeps it in the Keychain, then removes `password.txt` and every other key, so
  /// only this Mac and the user can open the backup. A key from an earlier `makeRecoveryKey` that
  /// was never confirmed goes too.
  public func turnOnPrivateBackup(confirming recoveryKey: String, now: Date = Date())
    async throws
  {
    try await commands.run {
      let session = try await openRepository(now: now)
      let confirmed = Session(host: session.host, key: recoveryKey, custody: .private)
      do {
        _ = try await restic(confirmed, isRecoveringKey: false) { try await $0.keys() }
      } catch ResticFailure.exited(.wrongPassword, _) {
        throw Failure.recoveryKeyDoesNotOpen
      }
      // Until the custody changes, the old key and `password.txt` still open the repository
      // too, so a crash here leaves one that opens with either.
      try keychain.save(recoveryKey)
      try store.setKeyCustody(.private)
      // Already private, the file is gone but the last recovery key isn't.
      // ponytail: a crash between the Keychain and here leaves that key working until the next
      // change of key; the user held it already. Un-park if a rotation is ever cut short.
      try await removeKeys(otherThan: confirmed)
      try await repository.removePasswordFile()
    }
  }

  /// Puts the key back beside the backup.
  public func turnOffPrivateBackup(now: Date = Date()) async throws {
    try await commands.run {
      let session = try await openRepository(now: now)
      try store.setKeyCustody(.besideBackup)
      try await settleCustody(Session(host: session.host, key: session.key, custody: .besideBackup))
    }
  }

  // MARK: - The repository

  /// What every command needs: whom the snapshots belong to and the key. The key is replaced
  /// when the Keychain's turns out stale and `password.txt` opens the repository.
  private final class Session: Sendable {
    let host: String
    let custody: KeyCustody
    private let currentKey: OSAllocatedUnfairLock<String>

    init(host: String, key: String, custody: KeyCustody) {
      self.host = host
      self.custody = custody
      currentKey = OSAllocatedUnfairLock(initialState: key)
    }

    var key: String { currentKey.withLock { $0 } }

    func replaceKey(with key: String) {
      currentKey.withLock { $0 = key }
    }
  }

  /// Opens the Mac's repository, creating it on first use with its key beside it, and makes it
  /// match the key's custody, which a crash in the middle of a change can leave half done.
  private func openRepository(now: Date) async throws -> Session {
    if let account = try store.backupAccount() {
      let key = try await existingKey()
      let session = Session(host: account.host, key: key, custody: account.keyCustody)
      try await settleCustody(session)
      return session
    }
    // The key is kept before the repository is made, so a repository never exists without it.
    let key = try await existingKeyIfAny() ?? RecoveryKey.make()
    try keychain.save(key)
    let session = Session(host: try Machine.id(), key: key, custody: .besideBackup)
    try await settleCustody(session)
    do {
      _ = try await restic(session) { try await $0.keys() }
    } catch ResticFailure.exited(.repositoryMissing, _) {
      _ = try await restic(session) { try await $0.createRepository() }
    }
    try store.createBackupAccount(host: session.host, now: now)
    return session
  }

  private func existingKey() async throws -> String {
    if let key = try keychain.key() { return key }
    guard let key = try await repository.readPasswordFile() else { throw Failure.keyMissing }
    try keychain.save(key)
    return key
  }

  /// The Keychain's copy, or the one beside the backup.
  private func existingKeyIfAny() async throws -> String? {
    if let key = try keychain.key() { return key }
    return try await repository.readPasswordFile()
  }

  /// Beside the backup: `password.txt` is there. Private: it isn't, and no other key opens the
  /// repository. Other keys go first, so the file never outlives the key it holds.
  private func settleCustody(_ session: Session) async throws {
    let hasPasswordFile = try await repository.hasPasswordFile()
    switch session.custody {
    case .besideBackup:
      guard !hasPasswordFile else { return }
      try await repository.writePasswordFile(session.key)
    case .private:
      guard hasPasswordFile else { return }
      try await removeKeys(otherThan: session)
      try await repository.removePasswordFile()
    }
  }

  private func removeKeys(otherThan session: Session) async throws {
    let keys = try await restic(session) { try await $0.keys() }
    for key in keys where !key.isCurrent {
      try await restic(session) { try await $0.removeKey(id: key.id) }
    }
  }

  /// The Keychain's key didn't open the repository. The one beside it does, if it's there and
  /// opens it (the Keychain kept a key the repository no longer has): it replaces the Keychain's
  /// copy. Otherwise only the recovery key can open the backup now.
  private func recoverKey(for session: Session) async throws {
    guard let besideKey = try await repository.readPasswordFile(), besideKey != session.key
    else { throw Failure.keyMissing }
    let beside = Session(host: session.host, key: besideKey, custody: session.custody)
    do {
      _ = try await withRestic(beside) { try await $0.keys() }
    } catch ResticFailure.exited(.wrongPassword, _) {
      throw Failure.keyMissing
    }
    try keychain.save(besideKey)
    session.replaceKey(with: besideKey)
    Self.logger.info("The Keychain's key was stale; the one beside the backup replaced it")
  }

  /// One restic command, against the repository as `withAddress` gives it for that command. It
  /// runs again once when it meets:
  /// - a lock: after `unlock`. Commands here run one at a time, so the lock is one a restic killed
  ///   before it could remove it.
  /// - the wrong password, unless `isRecoveringKey` is false: with the key beside the backup, if
  ///   that one opens it (`recoverKey`).
  private func restic<Result: Sendable>(
    _ session: Session, isRecoveringKey: Bool = true,
    _ command: @Sendable @escaping (Restic) async throws -> Result
  ) async throws -> Result {
    do {
      return try await withRestic(session, command)
    } catch ResticFailure.exited(.lockFailed, _) {
      try await withRestic(session) { try await $0.unlock() }
      return try await withRestic(session, command)
    } catch ResticFailure.exited(.wrongPassword, let message) {
      guard isRecoveringKey else { throw ResticFailure.exited(.wrongPassword, message: message) }
      try await recoverKey(for: session)
      return try await withRestic(session, command)
    }
  }

  private func withRestic<Result: Sendable>(
    _ session: Session, _ command: @Sendable @escaping (Restic) async throws -> Result
  ) async throws -> Result {
    try await repository.withAddress { [executable, cacheDirectory, qualityOfService] address in
      try await command(
        Restic(
          executable: executable, repository: address, password: session.key,
          cacheDirectory: cacheDirectory, qualityOfService: qualityOfService))
    }
  }
}

/// A Backup folder as every surface shows it, from the database alone.
public struct BackupStatus: Sendable, Equatable {
  /// When it last ran, or went on.
  public var lastRunAt: Date
  public var lastSuccessAt: Date?
  /// Why the last run failed; nil once one succeeds.
  public var lastError: String?
  public var failingSince: Date?
  public var failedRunsInARow: Int
  /// What the last backup couldn't read.
  public var skipped: [SkippedFile]
  /// What the user left out, besides `BackupDefaults`.
  public var leftOut: [LeaveOut]
  public var cloudOnlyCount: Int

  public init(
    lastRunAt: Date, lastSuccessAt: Date? = nil, lastError: String? = nil,
    failingSince: Date? = nil, failedRunsInARow: Int = 0, skipped: [SkippedFile] = [],
    leftOut: [LeaveOut] = [], cloudOnlyCount: Int = 0
  ) {
    self.lastRunAt = lastRunAt
    self.lastSuccessAt = lastSuccessAt
    self.lastError = lastError
    self.failingSince = failingSince
    self.failedRunsInARow = failedRunsInARow
    self.skipped = skipped
    self.leftOut = leftOut
    self.cloudOnlyCount = cloudOnlyCount
  }
}

extension RunProgress {
  init(folderID: Int64, _ progress: BackupProgress) {
    self.init(
      folderID: folderID, itemsDone: Int(progress.filesDone), itemsTotal: Int(progress.totalFiles),
      bytesDone: Int64(progress.bytesDone), bytesTotal: Int64(progress.totalBytes),
      current: progress.currentFiles.first.map { URL(fileURLWithPath: $0).lastPathComponent })
  }
}
