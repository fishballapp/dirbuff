import Foundation

@testable import DirBuffKit

/// A bridge to `DirBuff Backup/Test Mac` in an in-memory Drive, and the pinned restic to drive it.
struct BridgeFixture {
  let scratch: Scratch
  let drive: InMemoryDrive
  let store: Store
  let repository: DriveFileID
  let bridge: DriveBridge
  let restic: Restic

  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  init(
    drive: InMemoryDrive = InMemoryDrive(pageSize: 100),
    dailyUploadLimit: Int64 = DriveBridge.defaultDailyUploadLimit
  ) async throws {
    scratch = try Scratch()
    self.drive = drive
    store = try Store.inMemory()
    let backups = try await drive.createFolder(named: "DirBuff Backup", in: nil)
    repository = try await drive.createFolder(named: "Test Mac", in: backups.id).id
    bridge = DriveBridge(
      drive: drive, store: store, repository: repository, dailyUploadLimit: dailyUploadLimit,
      now: { Self.now })
    restic = try testRestic(in: scratch)
  }

  /// A folder to back up: a note, and a pack's worth of bytes that don't compress.
  func source(randomBytes: Int = 3_000_000) throws -> URL {
    let source = try scratch.folder("source")
    try Data("first".utf8).write(to: source.appendingPathComponent("notes.txt"))
    var noise = Data(count: randomBytes)
    noise.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
    try noise.write(to: source.appendingPathComponent("photo.raw"))
    return source
  }

  /// Copies the repository's folder out of Drive into `directory`, as a download of it would.
  func download(to directory: URL) async throws {
    try await download(repository, to: directory)
  }

  private func download(_ folder: DriveFileID, to directory: URL) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for item in try await drive.allChildren(of: folder) {
      let target = directory.appendingPathComponent(item.name)
      if item.isFolder {
        try await download(item.id, to: target)
      } else {
        try await drive.download(item.id, range: nil).write(to: target)
      }
    }
  }

  /// Every file (not folder) in the repository's folder on Drive, by its path there.
  func filesOnDrive() async throws -> [String: DriveItem] {
    try await files(in: repository, at: "")
  }

  private func files(in folder: DriveFileID, at path: String) async throws -> [String: DriveItem] {
    var files: [String: DriveItem] = [:]
    for item in try await drive.allChildren(of: folder) {
      let itemPath = path.isEmpty ? item.name : path + "/" + item.name
      if item.isFolder {
        files.merge(try await self.files(in: item.id, at: itemPath)) { $1 }
      } else {
        files[itemPath] = item
      }
    }
    return files
  }
}
