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
  /// Where the Macs' backups are, this Mac's among them.
  public let storage: any BackupStorage
  public let keychain: any BackupKeychain
  private let executable: URL
  /// restic's cache of the repositories' indexes.
  private let cacheDirectory: URL
  /// Whose `Library` a backup of their home leaves out.
  private let home: URL
  /// Folders of DirBuff's own that a backup leaves out wherever they are: the cache, and a
  /// repository on this Mac.
  private let ownFolders: [URL]
  private let qualityOfService: QualityOfService
  /// What this Mac's snapshots are taken as when it starts a repository of its own.
  let machineID: @Sendable () throws -> String
  /// Bytes free on the volume of a folder, for what a restore may write.
  let freeSpace: @Sendable (URL) throws -> Int64
  let commands = OneAtATime()
  var store: Store { engine.store }
  static let logger = Logger(subsystem: "app.fishball.dirbuff", category: "backup")

  /// How often `maintain` prunes the repository.
  public static let pruneInterval: TimeInterval = 7 * 86_400
  /// `prune` and `check` can go quiet for long stretches, so they have a limit on the clock.
  public static let pruneLimit = Duration.seconds(4 * 3_600)

  public init(
    engine: Engine, storage: any BackupStorage,
    keychain: any BackupKeychain = LoginKeychain(),
    executable: URL = Restic.bundledExecutable, cacheDirectory: URL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    ownFolders: [URL] = [], qualityOfService: QualityOfService = Restic.defaultQualityOfService,
    machineID: @escaping @Sendable () throws -> String = Machine.id,
    freeSpace: @escaping @Sendable (URL) throws -> Int64 = BackupBuff.volumeFreeSpace
  ) {
    self.engine = engine
    self.storage = storage
    self.keychain = keychain
    self.executable = executable
    self.cacheDirectory = cacheDirectory
    self.home = home
    self.ownFolders = [cacheDirectory] + ownFolders
    self.qualityOfService = qualityOfService
    self.machineID = machineID
    self.freeSpace = freeSpace
  }

  /// What macOS would let an app the user is waiting on write to the folder's volume.
  public static func volumeFreeSpace(of folder: URL) throws -> Int64 {
    try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage ?? 0
  }

  public enum Failure: Error, Equatable {
    /// The repository has a password, and none was given: another Mac's, or this Mac's when the
    /// Keychain lost it.
    case passwordNeeded
    /// The password given, or the one the Keychain keeps, doesn't open the repository.
    case passwordDoesNotOpen
    /// A password must have at least `minimum` characters.
    case passwordTooShort(minimum: Int)
    /// restic trims a password, so one that starts or ends with a space would open as another.
    case passwordHasSurroundingSpace
    /// A name to leave out can't hold a `/`; that's a path.
    case nameWithSlash(String)
    /// The snapshot doesn't hold the file or folder asked for.
    case notInBackup(String)
    /// The folder's volume hasn't room for what a restore would write.
    case notEnoughRoom(needed: Int64, available: Int64)
    /// A restore can't write into this folder; nothing was downloaded.
    case cannotWrite(URL)
    /// A folder on the way to where a copy would go is now a link out of the backed-up folder.
    case outsideFolder(String)
    /// Two folders on this Mac would back up as the one series.
    case seriesShared(String)
    /// The backup to take over lists no snapshot, so there's no Mac to take it over as.
    case backupIsEmpty
    /// The Google account can't be used until the user fixes this (kept for the states); the
    /// command didn't run, and nothing was recorded as a failed backup.
    case accountProblem(DriveAccountProblem)
    /// Start Again deletes nothing, but it leaves the old history behind for good, so the caller
    /// must say the user knows.
    case notConfirmed
    /// This storage can't make a second repository.
    case cannotStartAgain
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
    // A held backup isn't a failed one: it records nothing and waits for the account.
    try await storage.confirmUsable()
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
      await storage.noteFailure(error)
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

  /// What changed from the folder's last snapshot to this one, file by file; nil when it isn't
  /// known. The first snapshot of a series on this Mac has nothing before it, and a diff that
  /// failed tells nothing: the versions are followed again from that snapshot on.
  private func versions(
    from previous: String?, to snapshotID: String, in root: String, session: Session
  ) async throws -> [SavedVersion]? {
    guard let previous else { return nil }
    let changes: [DiffChange]
    do {
      changes = try await restic(session) { try await $0.diff(from: previous, to: snapshotID) }
    } catch {
      // ponytail: the snapshot is saved whatever the diff does, so a failed diff costs only this
      // run's lines on the Versions page, not the backup. Un-park if it's ever seen in the log.
      Self.logger.error(
        "Couldn't list what changed: \(String(describing: error), privacy: .public)")
      return nil
    }
    var saved: [SavedVersion] = []
    for change in changes {
      let path = String(change.path.drop { $0 == "/" }.dropLast(change.isFolder ? 1 : 0))
      // A folder is no version of anything, but one that took a file's place ends that file's
      // life on this Mac. (restic doesn't list what's in the new folder.)
      guard !change.isFolder || change.modifier == .typeChanged else { continue }
      if change.isFolder {
        saved.append(SavedVersion(path: path, change: .removed, size: nil))
        continue
      }
      let size = {
        try? FileManager.default.attributesOfItem(atPath: root + "/" + path)[.size] as? Int64
      }
      switch change.modifier {
      case .added: saved.append(SavedVersion(path: path, change: .added, size: size()))
      case .modified: saved.append(SavedVersion(path: path, change: .changed, size: size()))
      case .typeChanged:
        // A folder that a file took the place of is a file added, with no earlier version of the
        // file to bring back; a file that became a link is the same file changed.
        // Not knowing is the safe answer: a version before it that isn't there is never listed.
        let wasFile =
          (try? await restic(session) { try await $0.size(of: "/" + path, in: previous) })
          .flatMap { $0 } != nil
        saved.append(SavedVersion(path: path, change: wasFile ? .changed : .added, size: size()))
      case .removed: saved.append(SavedVersion(path: path, change: .removed, size: nil))
      case .metadataChanged, .unknown: continue
      }
    }
    return saved
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
    try await noticingAccount {
      try await commands.run {
        // Nothing was ever backed up on this Mac.
        guard let account = try store.backupAccount() else { return }
        try await storage.confirmUsable()
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
  }

  /// Runs `body`; if it fails because of the Google account, keeps the reason for the states.
  func noticingAccount<Result>(_ body: () async throws -> Result) async throws -> Result {
    do {
      return try await body()
    } catch {
      await storage.noteFailure(error)
      throw error
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

  // MARK: - The password

  /// The fewest characters a password may have.
  public static let minimumPasswordLength = 12

  /// Whether this Mac's repository opens only with a password, which the Keychain keeps. Without
  /// one, it opens with none.
  public func isPasswordProtected() throws -> Bool {
    try keychain.key() != nil
  }

  /// Protect with a Password, or change it: from now on the repository opens with `password`
  /// and nothing else. Nothing uploads again, since restic's keys each wrap the one master key.
  public func setPassword(_ password: String, now: Date = Date()) async throws {
    guard password.count >= Self.minimumPasswordLength else {
      throw Failure.passwordTooShort(minimum: Self.minimumPasswordLength)
    }
    guard password.trimmingCharacters(in: .whitespacesAndNewlines) == password else {
      throw Failure.passwordHasSurroundingSpace
    }
    try await replaceKey(with: password, now: now)
  }

  /// The repository opens with no password again.
  public func removePassword(now: Date = Date()) async throws {
    try await replaceKey(with: nil, now: now)
  }

  /// Marks the change pending, adds the new key, keeps it in the Keychain (or deletes the
  /// Keychain's for none), then removes every other key. Cut short anywhere, the repository
  /// opens with what the Keychain holds (before the Keychain changes the old key is there, after
  /// it the new one) and the next `openRepository` removes every other key. Asked again for the
  /// password it has, it finishes the change.
  private func replaceKey(with password: String?, now: Date) async throws {
    try await commands.run {
      let session = try await openRepository(now: now)
      try store.setKeyChangePending(true)
      if session.key != password {
        _ = try await restic(session) { try await $0.addKey(newPassword: password) }
        if let password { try keychain.save(password) } else { try keychain.delete() }
      }
      try await finishKeyChange(
        Session(repository: session.repository, host: session.host, key: password))
    }
  }

  /// Leaves only the key `session` opens the repository with.
  private func finishKeyChange(_ session: Session) async throws {
    let keys = try await restic(session) { try await $0.keys() }
    for key in keys where !key.isCurrent {
      try await restic(session) { try await $0.removeKey(id: key.id) }
    }
    try store.setKeyChangePending(false)
  }

  // MARK: - The repository

  /// What every command needs: the repository, whom the snapshots belong to, and the password,
  /// nil when it opens with none.
  struct Session: Sendable {
    let repository: any BackupRepository
    let host: String
    let key: String?
  }

  /// Opens the Mac's repository, creating it on first use with no password. A change cut short
  /// is finished first: a repository taken over gets its password into place, and a change of
  /// password leaves only the Keychain's key.
  ///
  /// `password`, typed on the backup page when this Mac's Keychain doesn't open the backup, only
  /// ever reads: it opens the repository and lists its snapshots, but never finishes a change of
  /// password (which removes keys), never creates the account or a repository, and never
  /// touches the Keychain. Only the Keychain's own key does those.
  func openRepository(now: Date, password: String? = nil) async throws -> Session {
    let session = try await openUnlistedRepository(now: now, password: password)
    try await listSnapshotsIfPending(session)
    return session
  }

  /// Makes the list of the snapshots the repository holds, from restic's own listing, when the
  /// database has none it trusts (after an upgrade, or a repository taken over). A listing that
  /// can't be made leaves it pending for the next command: the command itself goes on.
  private func listSnapshotsIfPending(_ session: Session) async throws {
    guard try store.isSnapshotListingPending() else { return }
    var listed: [Int64: [ResticSnapshot]] = [:]
    do {
      for wear in try store.backupWearers() {
        guard let record = try store.backupRecord(folderID: wear.folderID) else { continue }
        listed[wear.folderID] = try await restic(session) {
          try await $0.snapshots(tags: [record.resticTag], host: session.host)
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      Self.logger.error(
        "Couldn't list the snapshots: \(String(describing: error), privacy: .public)")
      return
    }
    try store.finishSnapshotListing(listed)
  }

  private func openUnlistedRepository(now: Date, password: String?) async throws -> Session {
    if try store.backupAccount()?.isAdoptionPending == true { try finishAdoption() }
    let repository = try await storage.thisMac()
    if let password {
      // Reading with what was typed: whatever is owed is left for the Keychain's key to finish.
      let host = try store.backupAccount()?.host ?? machineID()
      return Session(repository: repository, host: host, key: password)
    }
    if let account = try store.backupAccount() {
      let session = Session(repository: repository, host: account.host, key: try keychain.key())
      if account.isKeyChangePending { try await finishKeyChange(session) }
      return session
    }
    // A repository a crash left before the database knew of it opens as it is.
    let found = Session(repository: repository, host: try machineID(), key: try keychain.key())
    do {
      _ = try await restic(found) { try await $0.keys() }
      try store.createBackupAccount(host: found.host, now: now)
      return found
    } catch ResticFailure.exited(.repositoryMissing, _) {
      // A password the Keychain kept was an earlier repository's.
      try keychain.delete()
      let made = Session(repository: repository, host: found.host, key: nil)
      _ = try await restic(made) { try await $0.createRepository() }
      try store.createBackupAccount(host: made.host, now: now)
      return made
    }
  }

  /// Moves the password of a repository taken over from the staging slot to the Keychain's own,
  /// or, with none staged, takes the Keychain's away: that repository opens with no password.
  /// The staging slot is emptied last, after the database stops calling the adoption pending:
  /// emptied before, a quit between the two would read as "none staged" and lose the password.
  func finishAdoption() throws {
    if let staged = try keychain.key(.staged) {
      try keychain.save(staged)
    } else {
      try keychain.delete()
    }
    try store.finishAdoption()
    try keychain.delete(.staged)
  }

  /// One restic command, against the session's repository. A lock it meets is one a restic
  /// killed before it could remove it, since commands here run one at a time: it's cleared with
  /// `unlock` and the command runs again.
  func restic<Result: Sendable>(
    _ session: Session, _ command: @Sendable @escaping (Restic) async throws -> Result
  ) async throws -> Result {
    do {
      return try await withRestic(session, command)
    } catch ResticFailure.exited(.lockFailed, _) {
      try await withRestic(session) { try await $0.unlock() }
      return try await withRestic(session, command)
    }
  }

  /// One restic command, as it is: no lock cleared, for a repository that may be another Mac's.
  /// A password that doesn't open the repository is the user's to give.
  func withRestic<Result: Sendable>(
    _ session: Session, _ command: @Sendable @escaping (Restic) async throws -> Result
  ) async throws -> Result {
    do {
      return try await session.repository.serving(
        Restic(
          executable: executable, repository: "", password: session.key,
          cacheDirectory: cacheDirectory, qualityOfService: qualityOfService), command)
    } catch ResticFailure.exited(.wrongPassword, _) {
      throw session.key == nil ? Failure.passwordNeeded : Failure.passwordDoesNotOpen
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
