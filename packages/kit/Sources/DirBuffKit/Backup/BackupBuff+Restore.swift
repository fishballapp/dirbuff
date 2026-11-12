import Foundation

/// Restore: a file's versions, a copy of one, a folder as it was, and another Mac's backup on
/// this one. Each runs one at a time with the other commands, and none writes over anything.
extension BackupBuff {
  // MARK: This Mac's folders

  /// A file's versions, oldest first, from the database alone. A file with none is in every
  /// snapshot as the folder's first backup saved it, so its folder's newest snapshot holds it.
  public func versions(of path: String, folderID: Int64) throws -> [BackupVersion] {
    try store.backupVersions(folderID: folderID, path: path)
  }

  /// The folder's snapshots, oldest first, asked of the repository.
  public func snapshots(folderID: Int64, now: Date = Date()) async throws -> [ResticSnapshot] {
    try await commands.run {
      guard try store.backupAccount() != nil,
        let record = try store.backupRecord(folderID: folderID)
      else { return [] }
      let session = try await openRepository(now: now)
      return try await restic(session) { try await $0.snapshots(tags: [record.resticTag]) }
        .sorted { $0.time < $1.time }
    }
  }

  /// Restore: `item` as `backup` saved it, back where it was in the folder, once the folder's
  /// volume has room; or into `chosen` (Choose Folder…, when the folder isn't on this Mac now).
  /// It keeps its own name when nothing has that name there now; otherwise it goes beside what
  /// does, with the backup's date in its name ("Report (3 Mar 2027, 10.00).pages", "Finance
  /// (3 Mar 2027)"): nothing is replaced. restic writes it into a temporary folder on the same
  /// volume first, and it is moved into place whole, under a name nothing has. The folder is
  /// located when the restore's turn comes and again once the download is done, so one moved
  /// meanwhile is followed, and one removed from DirBuff gets nothing; a folder on the way that's
  /// now a link out of the folder is refused. The folder itself (`item.path` empty) is Restore
  /// Folder's. Returns where it went. `onProgress` hears how far a folder's download has got.
  public func restore(
    _ item: BackupItem, from backup: KeptBackup, folderID: Int64, into chosen: URL? = nil,
    password: String? = nil, onProgress: (@Sendable (RestoreProgress) -> Void)? = nil
  ) async throws -> URL {
    precondition(!item.path.isEmpty, "The folder itself is restored by restoreFolder")
    let name: @Sendable (Int) -> String = { number in
      number == 1
        ? item.name : RestorePlace.datedName(of: item, savedAt: backup.savedAt, number: number - 1)
    }
    return try await commands.run {
      if let chosen {
        let session = try await session(password: password)
        return try await RestorePlace.withTemporaryFolder(near: chosen) { temporary in
          let restored = try await extract(
            item, of: backup, session: session, into: temporary, roomIn: chosen,
            onProgress: onProgress)
          return try RestorePlace.move(restored, into: chosen, naming: name)
        }
      }
      // Where the folder is once its turn comes, which may be hours behind a backup.
      let folder = try engine.locate(folderID: folderID).url
      try RestorePlace.requireInside(folder, place(of: item, in: folder))
      let session = try await session(password: password)
      return try await RestorePlace.withTemporaryFolder(near: folder) { temporary in
        let restored = try await extract(
          item, of: backup, session: session, into: temporary, roomIn: folder,
          onProgress: onProgress)
        // Where it is now the download is done: moved or renamed meanwhile, it is followed. Then
        // the folders on the way, which may have gone or become links, are checked before any is
        // made for it, and again after.
        let folder = try engine.locate(folderID: folderID).url
        let directory = place(of: item, in: folder)
        try RestorePlace.requireInside(folder, directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try RestorePlace.requireInside(folder, directory)
        return try RestorePlace.move(restored, into: directory, naming: name)
      }
    }
  }

  /// The folder `item` was in, inside `folder`.
  private func place(of item: BackupItem, in folder: URL) -> URL {
    folder.appendingPathComponent(item.path).deletingLastPathComponent()
  }

  /// A copy of `item` as `backup` saved it, written to exactly `destination`: for a drag out to
  /// Finder, and for Quick Look. The folder itself (`item.path` empty) comes out whole. A file
  /// promise names its file before it is written: Finder has already made `destination`'s name
  /// one nothing in that folder has, and shows it under that name. So the copy goes there or
  /// nowhere: if something took that name meanwhile, this throws `EEXIST` rather than replace it
  /// or land under a name Finder doesn't know.
  public func download(
    _ item: BackupItem, from backup: KeptBackup, folderID: Int64, to destination: URL,
    password: String? = nil
  ) async throws -> URL {
    let directory = destination.deletingLastPathComponent()
    return try await commands.run {
      let session = try await session(password: password)
      return try await RestorePlace.withTemporaryFolder(near: directory) { temporary in
        let restored = try await extract(
          item, of: backup, session: session, into: temporary, roomIn: directory,
          onProgress: nil)
        return try RestorePlace.move(restored, to: destination)
      }
    }
  }

  /// The name Restore gives `item` when its own is taken: "Report (3 Mar 2027, 10.00).pages",
  /// "Finance (3 Mar 2027)".
  public static func datedName(of item: BackupItem, savedAt: Date) -> String {
    RestorePlace.datedName(of: item, savedAt: savedAt, number: 1)
  }

  /// Restore Folder: the folder as `backup` saved it, in a new folder beside it (or in
  /// `directory`, which a folder that isn't on this Mac now needs), "Documents (3 Mar 2027)", once its volume has room. Beside a folder whose
  /// parent can't be written to (a disk's top folder sits in `/Volumes`), this throws
  /// `cannotWrite` before anything downloads, for the caller to ask for a `directory`. Returns
  /// the new folder. `onProgress` hears how far the download has got.
  public func restoreFolder(
    folderID: Int64, backup: KeptBackup, into directory: URL? = nil, password: String? = nil,
    now: Date = Date(), onProgress: (@Sendable (RestoreProgress) -> Void)? = nil
  ) async throws -> URL {
    try await commands.run {
      // A folder that isn't on this Mac now can still come back, where the caller says.
      let located: URL?
      do {
        located = try engine.locate(folderID: folderID).url
      } catch {
        guard directory != nil else { throw error }
        located = nil
      }
      guard let destination = directory ?? located?.deletingLastPathComponent(),
        let name = try located?.lastPathComponent
          ?? store.folder(id: folderID).map({ URL(fileURLWithPath: $0.path).lastPathComponent })
      else { throw Engine.Failure.folderNotFound(id: folderID) }
      let session = try await session(password: password, now: now)
      return try await restore(
        snapshotID: backup.id, savedAt: backup.savedAt, size: nil, session: session,
        named: name, into: destination, onProgress: onProgress)
    }
  }

  /// Writes `item` from `backup` into `temporary` and returns where: a file by an include
  /// pattern, which fetches only its own blobs, and a folder as the snapshot's subfolder. A
  /// file's size is checked against the room first; a folder's is known only as restic counts
  /// it, so its restore stops the moment that count is more than the room.
  private func extract(
    _ item: BackupItem, of backup: KeptBackup, session: Session, into temporary: URL,
    roomIn place: URL, onProgress: (@Sendable (RestoreProgress) -> Void)?
  ) async throws -> URL {
    guard item.isFolder || item.path.isEmpty else {
      let size: Int64? =
        if let size = item.size {
          size
        } else if item.kind == .file {
          try await restic(session) { try await $0.size(of: "/" + item.path, in: backup.id) }
        } else {
          0
        }
      guard let size else { throw Failure.notInBackup(item.path) }
      try requireRoom(for: size, in: place)
      _ = try await restic(session) {
        try await $0.restore(
          snapshot: backup.id, to: temporary,
          including: [RestorePlace.pattern(matching: item.path)])
      }
      let restored = temporary.appendingPathComponent(item.path)
      // Not `fileExists`, which follows a link to what it points at.
      guard (try? FileManager.default.attributesOfItem(atPath: restored.path)) != nil else {
        throw Failure.notInBackup(item.path)
      }
      return restored
    }
    let restored = temporary.appendingPathComponent("restored")
    let available = try freeSpace(place)
    let room = RoomWatch(available: available)
    do {
      _ = try await restic(session) { restic in
        try await room.run { hear in
          try await restic.restore(
            snapshot: item.path.isEmpty ? backup.id : "\(backup.id):/\(item.path)", to: restored,
            onProgress: { progress in
              hear(progress)
              onProgress?(progress)
            })
        }
      }
    } catch ResticFailure.exited(.failed, let message) where message.hasSuffix(": not found") {
      throw Failure.notInBackup(item.path)
    } catch {
      if let needed = room.needed {
        throw Failure.notEnoughRoom(needed: needed, available: available)
      }
      throw error
    }
    return restored
  }

  // MARK: Restore from Google Drive

  /// Every Mac's backup in the storage, this one's among them.
  public func backedUpMacs() async throws -> [BackedUpMac] {
    try await commands.run { try await storage.macs() }
  }

  /// The folders `mac`'s backup holds, each with its snapshots. A backup with a password opens
  /// only with it: without, this throws `passwordNeeded`.
  public func backedUpFolders(of mac: BackedUpMac, password: String? = nil)
    async throws -> [BackedUpFolder]
  {
    try await commands.run {
      let session = try await session(of: mac, password: password)
      let snapshots = try await withRestic(session) { try await $0.snapshots() }
      return Dictionary(grouping: snapshots) { $0.tags.compactMap(BackupRecord.series).first }
        .compactMap { series, snapshots in
          let snapshots = snapshots.sorted { $0.time < $1.time }
          guard let series, let newest = snapshots.last, let path = newest.paths.first else {
            return nil
          }
          return BackedUpFolder(
            series: series, name: URL(fileURLWithPath: path).lastPathComponent, path: path,
            snapshots: snapshots)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
  }

  /// The folder as `snapshot` saved it, in a new folder in `directory` named
  /// "Documents (3 Mar 2027)", once its volume has room. Returns the new folder. `onProgress`
  /// hears how far the download has got.
  public func restore(
    _ snapshot: ResticSnapshot, of folder: BackedUpFolder, from mac: BackedUpMac,
    into directory: URL, password: String? = nil,
    onProgress: (@Sendable (RestoreProgress) -> Void)? = nil
  ) async throws -> URL {
    try await commands.run {
      let session = try await session(of: mac, password: password)
      return try await restore(
        snapshotID: snapshot.id, savedAt: snapshot.time, size: snapshot.size, session: session,
        named: folder.name, into: directory, onProgress: onProgress)
    }
  }

  /// Keep Backing Up Here: this Mac takes over `mac`'s repository as that Mac, with its
  /// snapshots' host, and keeps its password, if it has one, in the Keychain; so what's restored
  /// from it is found there and doesn't upload again. Each folder in `continuing`, by where it
  /// is on this Mac, is added to DirBuff and wears Backup on the series of the backed-up folder it
  /// was restored from: one folder to a series, and none is added until everything that can fail
  /// has not. The repository this Mac had stays where it is, and nothing backs up into it any more;
  /// every Backup folder, those too, is owed a first backup into the one it takes.
  ///
  /// `owner` is the Google account signed in, whose Drive the repository was listed in: it becomes
  /// the backup's owner in the same write as the repository, as Start a New Backup Here does, so
  /// a check never reads the repository as another account's. Without one (a repository in a
  /// folder, for tests) the owner stays as it was.
  ///
  /// Everything that asks the network comes first: listing the repository afresh, and its
  /// snapshots, which proves the password. Then the database changes in one write, marked
  /// pending until the password has moved from the Keychain's staging slot to its own. Cut short
  /// before that write, nothing has changed; after it, the next command finishes it.
  public func keepBackingUpHere(
    _ mac: BackedUpMac, password: String? = nil, continuing: [URL: BackedUpFolder] = [:],
    as owner: BackupOwner? = nil, now: Date = Date()
  ) async throws {
    let twice = Dictionary(grouping: continuing.values, by: \.series).first { $1.count > 1 }
    if let twice { throw Failure.seriesShared(twice.key) }
    try await commands.run {
      guard !mac.isThisMac else {
        let (series, added) = try addFolders(continuing, now: now)
        try undoingAdds(added) {
          if let shared = try store.sharedBackupSeries(series) {
            throw Failure.seriesShared(shared)
          }
          try store.continueBackupSeries(series, settings: defaultSettings, now: now)
        }
        return
      }
      let session = try await session(of: mac, password: password)
      // A snapshot restic couldn't read is left out of the list, not failed on, so an empty list
      // may be a Drive that didn't answer: no host to take.
      // ponytail: snapshots from several hosts in one repository arise only when two Macs back
      // up into one, which DirBuff doesn't do; the newest's host is taken. Un-park if seen.
      guard
        let newest = try await withRestic(session, { try await $0.snapshots() })
          .max(by: { $0.time < $1.time })
      else { throw Failure.backupIsEmpty }
      let (series, added) = try addFolders(continuing, now: now)
      try undoingAdds(added) {
        if let shared = try store.sharedBackupSeries(series) { throw Failure.seriesShared(shared) }
        if let password {
          try keychain.save(password, in: .staged)
        } else {
          try keychain.delete(.staged)
        }
        try store.adoptBackupRepository(
          host: newest.hostname, repository: mac.id, series: series, settings: defaultSettings,
          now: now, owner: owner)
      }
      try finishAdoption()
    }
  }

  // MARK: Inside

  /// Adds the restored folders to DirBuff, by series; those that weren't already added are
  /// returned too, for `undoingAdds`.
  private func addFolders(_ folders: [URL: BackedUpFolder], now: Date) throws
    -> (series: [Int64: String], added: [Folder])
  {
    var series: [Int64: String] = [:]
    var added: [Folder] = []
    do {
      for (url, folder) in folders {
        let existing = try store.folder(path: try canonicalPath(of: url))
        let folderAdded = try engine.add(url, now: now)
        if existing == nil { added.append(folderAdded) }
        series[try require(folderAdded.id)] = folder.series
      }
    } catch {
      for folder in added { try? engine.remove(folder) }
      throw error
    }
    return (series, added)
  }

  /// Runs `body`; if it throws, the folders that were added for it go again, so a Keep Backing Up
  /// Here that didn't happen leaves DirBuff's folders as they were.
  private func undoingAdds(_ added: [Folder], _ body: () throws -> Void) throws {
    do {
      try body()
    } catch {
      for folder in added { try? engine.remove(folder) }
      throw error
    }
  }

  /// A session on `mac`'s repository that only reads, with the password given; this Mac's opens
  /// with the Keychain's when none is.
  private func session(of mac: BackedUpMac, password: String?) async throws -> Session {
    let repository = try await storage.repository(of: mac)
    let key = try password ?? (mac.isThisMac ? keychain.key() : nil)
    // Nothing selects by host.
    return Session(repository: repository, host: mac.name, key: key)
  }

  /// Checks the folder can be written to before anything downloads.
  private func restore(
    snapshotID: String, savedAt: Date, size: Int64?, session: Session, named name: String,
    into directory: URL, onProgress: (@Sendable (RestoreProgress) -> Void)?
  ) async throws -> URL {
    guard FileManager.default.isWritableFile(atPath: directory.path) else {
      throw Failure.cannotWrite(directory)
    }
    let size: Int64 =
      if let size {
        size
      } else {
        try await withRestic(session) { try await $0.restoreSize(of: snapshotID) }
      }
    try requireRoom(for: size, in: directory)
    return try await RestorePlace.withTemporaryFolder(near: directory) { temporary in
      let restored = temporary.appendingPathComponent("restored")
      _ = try await withRestic(session) {
        try await $0.restore(snapshot: snapshotID, to: restored, onProgress: onProgress)
      }
      return try RestorePlace.move(restored, into: directory) {
        RestorePlace.folderName(name, savedAt: savedAt, number: $0)
      }
    }
  }
}

extension BackupBuff {
  private func requireRoom(for needed: Int64, in folder: URL) throws {
    let available = try freeSpace(folder)
    guard needed <= available else {
      throw Failure.notEnoughRoom(needed: needed, available: available)
    }
  }
}

/// A folder in a Mac's backup: one series of snapshots.
public struct BackedUpFolder: Sendable, Equatable {
  /// Its series in the repository (`--tag folder=<series>`).
  public var series: String
  /// The folder's name when it was last backed up.
  public var name: String
  /// Where it was on its Mac then.
  public var path: String
  /// Oldest first.
  public var snapshots: [ResticSnapshot]

  public init(series: String, name: String, path: String, snapshots: [ResticSnapshot]) {
    self.series = series
    self.name = name
    self.path = path
    self.snapshots = snapshots
  }
}

/// Stops a restore whose size, as restic counts it while it goes, is more than the room there is.
private final class RoomWatch: @unchecked Sendable {
  private let available: Int64
  private let lock = NSLock()
  private var task: Task<RestoreSummary, any Error>?
  private var over: Int64?

  init(available: Int64) {
    self.available = available
  }

  /// What the restore needs, once it is more than the room.
  var needed: Int64? { lock.withLock { over } }

  /// Runs `body`, which hands what restic reports to `hear`, and stops it once it needs more.
  func run(
    _ body:
      @escaping @Sendable (@escaping @Sendable (RestoreProgress) -> Void) async throws
      -> RestoreSummary
  ) async throws -> RestoreSummary {
    let task = Task { try await body { self.hear($0) } }
    lock.withLock {
      self.task = task
      if over != nil { task.cancel() }
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func hear(_ progress: RestoreProgress) {
    lock.withLock {
      guard over == nil, Int64(progress.totalBytes) > available else { return }
      over = Int64(progress.totalBytes)
      task?.cancel()
    }
  }
}

/// Where a restore puts what it wrote, and under what name.
enum RestorePlace {
  /// A folder on the same volume as `folder`, so what's restored into it moves out by a rename,
  /// whole or not at all. It goes when `body` ends.
  static func withTemporaryFolder<Result>(
    near folder: URL, _ body: (URL) async throws -> Result
  ) async throws -> Result {
    let temporary = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    return try await body(temporary)
  }

  /// Moves `item` into `directory` under the first of `name(1)`, `name(2)`, … that nothing
  /// there has. The rename refuses to replace anything, so nothing is overwritten even by a file
  /// that appears meanwhile. A restore cancelled after restic finished moves nothing.
  static func move(_ item: URL, into directory: URL, naming name: (Int) -> String) throws -> URL {
    try Task.checkCancellation()
    var number = 1
    while true {
      let target = directory.appendingPathComponent(name(number))
      if renamex_np(item.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
      guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      number += 1
    }
  }

  /// Moves `item` to exactly `target`, refusing to replace anything there (`EEXIST`).
  static func move(_ item: URL, to target: URL) throws -> URL {
    try Task.checkCancellation()
    guard renamex_np(item.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return target
  }

  /// "Report (3 Mar 2027, 10.00).pages", then "Report (3 Mar 2027, 10.00) 2.pages". The time
  /// has a dot: Finder shows a colon in a name as a slash.
  static func copyName(of fileName: String, savedAt: Date, number: Int) -> String {
    let name = fileName as NSString
    let time = Calendar.current.dateComponents([.hour, .minute], from: savedAt)
    let stamp =
      savedAt.formatted(date: .abbreviated, time: .omitted)
      + String(format: ", %02d.%02d", time.hour ?? 0, time.minute ?? 0)
    let base = "\(name.deletingPathExtension) (\(stamp))" + (number > 1 ? " \(number)" : "")
    return name.pathExtension.isEmpty ? base : base + "." + name.pathExtension
  }

  /// A copy's name for `item` (`copyName` for a file or link, `folderName` for a folder).
  static func datedName(of item: BackupItem, savedAt: Date, number: Int) -> String {
    item.isFolder
      ? folderName(item.name, savedAt: savedAt, number: number)
      : copyName(of: item.name, savedAt: savedAt, number: number)
  }

  /// "Documents (3 Mar 2027)", then "Documents (3 Mar 2027) 2".
  static func folderName(_ name: String, savedAt: Date, number: Int) -> String {
    "\(name) (\(savedAt.formatted(date: .abbreviated, time: .omitted)))"
      + (number > 1 ? " \(number)" : "")
  }

  /// Throws `outsideFolder` when `directory`, or the nearest of its parents that exists, is
  /// really somewhere outside `folder`: a folder on the way was replaced by a link.
  static func requireInside(_ folder: URL, _ directory: URL) throws {
    let root = try realPath(folder)
    var existing = directory
    while !FileManager.default.fileExists(atPath: existing.path) {
      existing.deleteLastPathComponent()
    }
    let real = try realPath(existing)
    guard real == root || real.hasPrefix(root + "/") else {
      throw BackupBuff.Failure.outsideFolder(directory.path)
    }
  }

  /// The path with every link in it followed.
  private static func realPath(_ url: URL) throws -> String {
    guard let resolved = realpath(url.path, nil) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// restic's `--include` pattern for exactly the file at `path` inside the snapshot.
  static func pattern(matching path: String) -> String {
    "/"
      + path.reduce(into: "") { pattern, character in
        if "*?[]\\".contains(character) { pattern.append("\\") }
        pattern.append(character)
      }
  }
}
