import DirBuffCore
import Foundation
import Security
import os

@testable import DirBuffKit

/// A Keychain of its own for each test: the real one is tested by `SystemTests`.
struct TestKeychain: BackupKeychain {
  private let stored = OSAllocatedUnfairLock<[BackupKeychainSlot: String]>(initialState: [:])

  func key(_ slot: BackupKeychainSlot) throws -> String? { stored.withLock { $0[slot] } }
  func save(_ key: String, in slot: BackupKeychainSlot) throws {
    stored.withLock { $0[slot] = key }
  }
  func delete(_ slot: BackupKeychainSlot) throws { stored.withLock { $0[slot] = nil } }
}

/// Backup on folders under one scratch folder: the repository, restic's cache and a home of its
/// own are in it too.
struct BackupFixture {
  let scratch: Scratch
  let engine: Engine
  let keychain = TestKeychain()
  let backup: BackupBuff
  var repositoryFolder: URL { scratch.url.appendingPathComponent("repository") }
  var home: URL { scratch.url.appendingPathComponent("home") }

  init() throws {
    scratch = try Scratch()
    engine = Engine(store: try Store.inMemory())
    backup = BackupBuff(
      engine: engine,
      storage: LocalRepository(folder: scratch.url.appendingPathComponent("repository")),
      keychain: keychain,
      executable: try resticExecutable(),
      cacheDirectory: scratch.url.appendingPathComponent("cache"),
      home: scratch.url.appendingPathComponent("home"),
      // Background work crawls on a busy Mac; what runs at that priority is tested on its own.
      qualityOfService: .userInitiated)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  }

  var store: Store { engine.store }

  /// Adds the folder at `path` in the scratch folder and puts Backup on it; returns its id.
  func addWearing(_ path: String) throws -> Int64 {
    let folder = try scratch.folder(path)
    let id = try require(engine.add(folder).id)
    try backup.putOn(folderID: id)
    return id
  }

  @discardableResult
  func run(_ folderID: Int64, at date: Date = Date(), runID: Int64? = nil) async throws
    -> RunSummary
  {
    try await backup.run(
      engine.locate(folderID: folderID), require(backup.wear(folderID: folderID)),
      context: RunContext(runID: runID, scheduledAt: date))
  }

  func record(_ folderID: Int64) throws -> BackupRecord {
    try require(store.backupRecord(folderID: folderID))
  }

  /// The real restic on the repository, opened as this Mac opens it.
  func restic() throws -> Restic {
    try testRestic(in: scratch, password: keychain.key())
  }

  func snapshots(_ folderID: Int64) async throws -> [ResticSnapshot] {
    try await restic().snapshots(tags: [record(folderID).resticTag])
  }

  /// The folder's latest snapshot, restored into a new folder.
  func restoredLatest(_ folderID: Int64) async throws -> URL {
    let target = try scratch.folder("restored-\(UUID().uuidString)")
    _ = try await restic().restore(
      snapshot: require(record(folderID).lastSnapshotID), to: target)
    return target
  }

  /// `restic check`, reading every byte. A restic killed during a backup leaves its lock behind,
  /// and `check` needs the repository to itself, so the locks of restics that are gone go first,
  /// as Backup's own commands clear them when they meet one.
  func isHealthy() async throws -> Bool {
    let restic = try restic()
    try await restic.unlock()
    return try await restic.check(readDataSubset: "100%", wallClockLimit: .seconds(300)).isHealthy
  }
}

/// `count` bytes nobody can compress or find twice.
func randomData(_ count: Int) -> Data {
  var data = Data(count: count)
  data.withUnsafeMutableBytes { buffer in
    guard let bytes = buffer.baseAddress else { return }
    _ = SecRandomCopyBytes(kSecRandomDefault, count, bytes)
  }
  return data
}

/// Every regular file under `folder`, by its path inside it, with its contents.
func contents(of folder: URL) throws -> [String: Data] {
  let root = try canonicalPath(of: folder)
  let files = FileManager.default.enumerator(
    at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isRegularFileKey])
  return try (files?.allObjects as? [URL] ?? []).reduce(into: [:]) { contents, file in
    guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      return
    }
    contents[String(try canonicalPath(of: file).dropFirst(root.count + 1))] = try Data(
      contentsOf: file)
  }
}
