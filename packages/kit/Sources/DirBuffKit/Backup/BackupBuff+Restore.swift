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

  /// The folder's snapshots, oldest first: the dates Restore Folder offers.
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

  /// Restore a Copy: the file as `version` saved it, beside the original as
  /// "Report (3 Mar 2027, 10.00).pages", once its volume has room. restic writes it into a
  /// temporary folder on the same volume first, and it's moved into place only under a name
  /// nothing has. A folder on the way that's now a link out of the folder is refused. Returns
  /// where it went.
  public func restoreCopy(_ version: BackupVersion, folderID: Int64, now: Date = Date())
    async throws -> URL
  {
    guard version.change != .removed else { throw Failure.nothingToRestore }
    let folder = try engine.locate(folderID: folderID).url
    let original = folder.appendingPathComponent(version.path)
    try RestorePlace.requireInside(folder, original.deletingLastPathComponent())
    return try await commands.run {
      let session = try await openRepository(now: now)
      let size: Int64? =
        if let size = version.size {
          size
        } else {
          try await restic(session) {
            try await $0.size(of: "/" + version.path, in: version.snapshotID)
          }
        }
      guard let size else { throw Failure.notInBackup(version.path) }
      try requireRoom(for: size, in: folder)
      return try await RestorePlace.withTemporaryFolder(near: folder) { temporary in
        _ = try await restic(session) {
          try await $0.restore(
            snapshot: version.snapshotID, to: temporary,
            including: [RestorePlace.pattern(matching: version.path)])
        }
        let restored = temporary.appendingPathComponent(version.path)
        guard FileManager.default.fileExists(atPath: restored.path) else {
          throw Failure.notInBackup(version.path)
        }
        // The folder it was in may have gone since.
        let directory = original.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try RestorePlace.move(restored, into: directory) {
          RestorePlace.copyName(
            of: original.lastPathComponent, savedAt: version.savedAt, number: $0)
        }
      }
    }
  }

  /// Restore Folder: the folder as `snapshot` saved it, in a new folder beside it (or in
  /// `directory`), "Documents (3 Mar 2027)", once its volume has room. Beside a folder whose
  /// parent can't be written to (a disk's top folder sits in `/Volumes`), this throws
  /// `cannotWrite` before anything downloads, for the caller to ask for a `directory`. Returns
  /// the new folder.
  public func restoreFolder(
    folderID: Int64, snapshot: ResticSnapshot, into directory: URL? = nil, now: Date = Date()
  ) async throws -> URL {
    let folder = try engine.locate(folderID: folderID).url
    let destination = directory ?? folder.deletingLastPathComponent()
    return try await commands.run {
      let session = try await openRepository(now: now)
      return try await restore(
        snapshot, session: session, named: folder.lastPathComponent, into: destination)
    }
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
  /// "Documents (3 Mar 2027)", once its volume has room. Returns the new folder.
  public func restore(
    _ snapshot: ResticSnapshot, of folder: BackedUpFolder, from mac: BackedUpMac,
    into directory: URL, password: String? = nil
  ) async throws -> URL {
    try await commands.run {
      let session = try await session(of: mac, password: password)
      return try await restore(snapshot, session: session, named: folder.name, into: directory)
    }
  }

  /// Keep Backing Up Here: this Mac takes over `mac`'s repository as that Mac, with its
  /// snapshots' host, and keeps its password, if it has one, in the Keychain; so what's restored
  /// from it is found there and doesn't upload again. Each folder in `continuing`, a folder of
  /// this Mac's by ID, wears Backup on the series of the backed-up folder it was restored from.
  /// The repository this Mac had stays where it is, and nothing backs up into it any more.
  ///
  /// Everything that asks the network comes first: listing the repository afresh, and its
  /// snapshots, which proves the password. Then the database changes in one write, marked
  /// pending until the password has moved from the Keychain's staging slot to its own. Cut short
  /// before that write, nothing has changed; after it, the next command finishes it.
  public func keepBackingUpHere(
    _ mac: BackedUpMac, password: String? = nil, continuing: [Int64: BackedUpFolder] = [:],
    now: Date = Date()
  ) async throws {
    let series = continuing.mapValues(\.series)
    try await commands.run {
      if let shared = try store.sharedBackupSeries(series) { throw Failure.seriesShared(shared) }
      guard !mac.isThisMac else {
        try store.continueBackupSeries(series, settings: defaultSettings, now: now)
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
      if let password {
        try keychain.save(password, in: .staged)
      } else {
        try keychain.delete(.staged)
      }
      try store.adoptBackupRepository(
        host: newest.hostname, repository: mac.id, series: series, settings: defaultSettings,
        now: now)
      try finishAdoption()
    }
  }

  // MARK: Inside

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
    _ snapshot: ResticSnapshot, session: Session, named name: String, into directory: URL
  ) async throws -> URL {
    guard FileManager.default.isWritableFile(atPath: directory.path) else {
      throw Failure.cannotWrite(directory)
    }
    let size: Int64 =
      if let size = snapshot.size {
        size
      } else {
        try await withRestic(session) { try await $0.restoreSize(of: snapshot.id) }
      }
    try requireRoom(for: size, in: directory)
    return try await RestorePlace.withTemporaryFolder(near: directory) { temporary in
      let restored = temporary.appendingPathComponent("restored")
      _ = try await withRestic(session) {
        try await $0.restore(snapshot: snapshot.id, to: restored)
      }
      return try RestorePlace.move(restored, into: directory) {
        RestorePlace.folderName(name, savedAt: snapshot.time, number: $0)
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
  /// that appears meanwhile.
  static func move(_ item: URL, into directory: URL, naming name: (Int) -> String) throws -> URL {
    var number = 1
    while true {
      let target = directory.appendingPathComponent(name(number))
      if renamex_np(item.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
      guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      number += 1
    }
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
