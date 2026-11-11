import CryptoKit
import Foundation

/// The weekly check: proves the backup is whole, not only that the last run finished.
extension BackupBuff {
  public static let checkInterval: TimeInterval = 7 * 86_400
  /// How much of the packs the check downloads and reads. Downloads come out of the egress every
  /// user of the app shares each day, so it's small and fixed.
  public static let checkReadSubset = "100M"
  /// The largest file the check restores: one this small is one blob, named by its SHA-256, so
  /// what's restored can be compared with what was saved.
  static let sampleSizeLimit: Int64 = 512 << 10
  /// How many folders of a snapshot the check opens looking for such a file.
  static let sampleSearchLimit = 10

  /// The last check that ran to its end; nil before the first.
  public func lastCheck() throws -> BackupCheck? {
    guard let account = try store.backupAccount(), let checkedAt = account.lastCheckAt else {
      return nil
    }
    return BackupCheck(checkedAt: checkedAt, problem: account.lastCheckProblem)
  }

  /// Whether a week has passed since the last check, on a Mac that has a backup to check.
  public func isCheckDue(now: Date = Date()) throws -> Bool {
    guard let account = try store.backupAccount() else { return false }
    guard let checkedAt = account.lastCheckAt else { return true }
    return now.timeIntervalSince(checkedAt) >= Self.checkInterval
  }

  /// In order, stopping at the first problem:
  /// 1. lists the repository afresh from the store, never from what this Mac remembers of it,
  ///    and counts a file this Mac wrote and the store no longer holds as missing, before restic
  ///    is asked anything (a lost `config` or key stops restic opening it at all);
  /// 2. runs `restic check` on what that listing holds;
  /// 3. reads `checkReadSubset` of the packs;
  /// 4. restores one small file and compares it with its hash, from the snapshot after the one
  ///    the last check took, so every age of snapshot takes its turn.
  ///
  /// Records what it found and returns it; nil when nothing was ever backed up. restic failing
  /// on the repository is a problem found. Only a check that couldn't reach it (offline, signed
  /// out, a password the Keychain lost) or was stopped throws, and records nothing.
  @discardableResult
  public func check(now: Date = Date()) async throws -> BackupCheck? {
    try await noticingAccount {
      try await commands.run {
        guard let account = try store.backupAccount() else { return nil }
        let session = try await openRepository(now: now)
        let missing = try await session.repository.refreshListing()
        guard missing.isEmpty else {
          let problem =
            "\(missing.count) files are missing from the backup's storage: "
            + missing.prefix(5).joined(separator: ", ") + (missing.count > 5 ? ", …" : "")
          return try record(BackupCheck(checkedAt: now, problem: problem), sampledAt: nil)
        }
        do {
          let (problem, sampledAt) = try await checkRepository(session, account: account)
          return try record(BackupCheck(checkedAt: now, problem: problem), sampledAt: sampledAt)
        } catch ResticFailure.exited(let exit, let message)
          where exit != .lockFailed && exit != .cancelled
        {
          let problem = "restic couldn't read the backup: \(message)"
          return try record(BackupCheck(checkedAt: now, problem: problem), sampledAt: nil)
        }
      }
    }
  }

  /// Steps 2 to 4: the problem found, if any, and the time of the snapshot sampled.
  private func checkRepository(_ session: Session, account: BackupAccount) async throws
    -> (problem: String?, sampledAt: Date?)
  {
    let structure = try await restic(session) {
      try await $0.check(wallClockLimit: Self.pruneLimit)
    }
    if let problem = Self.problem(structure) { return (problem, nil) }
    let read = try await restic(session) {
      try await $0.check(readDataSubset: Self.checkReadSubset, wallClockLimit: Self.pruneLimit)
    }
    if let problem = Self.problem(read) { return (problem, nil) }
    let snapshots = try await restic(session) { try await $0.snapshots(host: session.host) }
      .sorted { $0.time < $1.time }
    // The last one's time is kept to the millisecond, so one in the same millisecond is it.
    let isAfterLast = { (snapshot: ResticSnapshot) in
      account.lastSampledAt.map { snapshot.time.timeIntervalSince($0) >= 0.001 } ?? true
    }
    guard let snapshot = snapshots.first(where: isAfterLast) ?? snapshots.first else {
      return (nil, nil)
    }
    return (try await sampleProblem(in: snapshot, session: session), snapshot.time)
  }

  private static func problem(_ summary: CheckSummary) -> String? {
    guard !summary.isHealthy else { return nil }
    return "restic check found \(summary.numErrors) errors"
      + (summary.brokenPacks.isEmpty ? "" : ", \(summary.brokenPacks.count) packs damaged")
  }

  private func record(_ check: BackupCheck, sampledAt: Date?) throws -> BackupCheck {
    try store.recordCheck(check, sampledAt: sampledAt)
    if let problem = check.problem {
      Self.logger.error("The weekly check found a problem: \(problem, privacy: .public)")
    }
    return check
  }

  /// Restores a small file of the snapshot and says what's wrong with it, if anything.
  func sampleProblem(in snapshot: ResticSnapshot, session: Session) async throws
    -> String?
  {
    guard let (path, hash) = try await smallFile(in: snapshot, session: session) else {
      return nil
    }
    let sample = "\(path) in the snapshot of \(snapshot.time.formatted())"
    return try await RestorePlace.withTemporaryFolder(near: FileManager.default.temporaryDirectory)
    { temporary in
      do {
        _ = try await restic(session) {
          try await $0.restore(
            snapshot: snapshot.id, to: temporary,
            including: [RestorePlace.pattern(matching: path)])
        }
      } catch ResticFailure.exited(_, let message) {
        return "Couldn't restore \(sample): \(message)"
      }
      guard let data = FileManager.default.contents(atPath: temporary.path + "/" + path) else {
        return "Couldn't restore \(sample)"
      }
      let restored = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      return restored == hash ? nil : "\(sample) came back changed"
    }
  }

  /// A file of one blob, its path inside the snapshot and its hash, from the first folders of the
  /// snapshot, nearest the top first.
  func smallFile(in snapshot: ResticSnapshot, session: Session) async throws
    -> (path: String, hash: String)?
  {
    var folders = [""]
    var opened = 0
    while !folders.isEmpty, opened < Self.sampleSearchLimit {
      let folder = folders.removeFirst()
      opened += 1
      let nodes = try await restic(session) {
        try await $0.tree(snapshot: snapshot.id, path: folder.isEmpty ? "/" : folder)
      }
      for node in nodes where node.isFile {
        guard let size = node.size, 0 < size, size <= Self.sampleSizeLimit,
          let content = node.content, content.count == 1, let hash = content.first
        else { continue }
        return (String((folder + "/" + node.name).dropFirst()), hash)
      }
      folders += nodes.filter(\.isFolder).map { folder + "/" + $0.name }
    }
    return nil
  }
}

/// What a weekly check found.
public struct BackupCheck: Sendable, Equatable {
  public var checkedAt: Date
  /// What's missing or damaged, in words for Show Details; nil when the backup is whole.
  public var problem: String?

  public var isWhole: Bool { problem == nil }

  public init(checkedAt: Date, problem: String?) {
    self.checkedAt = checkedAt
    self.problem = problem
  }
}
