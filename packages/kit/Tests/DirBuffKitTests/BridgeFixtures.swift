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
    try await drive.export(repository, to: directory)
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

/// An in-memory Drive whose uploads go through `upload` instead, for a test to hold, fail or send
/// them elsewhere.
struct InterceptedDrive: DriveFiles {
  let kept: InMemoryDrive
  let upload: @Sendable (Data, String, DriveFileID) async throws -> DriveItem

  func upload(_ data: Data, named name: String, in folder: DriveFileID) async throws -> DriveItem {
    try await upload(data, name, folder)
  }

  func about() async throws -> DriveAbout { try await kept.about() }
  func createFolder(named name: String, in parent: DriveFileID?) async throws -> DriveItem {
    try await kept.createFolder(named: name, in: parent)
  }
  func children(of folder: DriveFileID, after pageToken: String?) async throws -> DrivePage {
    try await kept.children(of: folder, after: pageToken)
  }
  func created(after pageToken: String?) async throws -> DrivePage {
    try await kept.created(after: pageToken)
  }
  func metadata(of id: DriveFileID) async throws -> DriveItem { try await kept.metadata(of: id) }
  func download(_ id: DriveFileID, range: Range<Int64>?) async throws -> Data {
    try await kept.download(id, range: range)
  }
  func delete(_ id: DriveFileID) async throws { try await kept.delete(id) }
  func untrash(_ id: DriveFileID) async throws -> DriveItem { try await kept.untrash(id) }
}

/// Lets tasks go on only once `count` of them have arrived, so a test knows they are all under
/// way at once.
actor Rendezvous {
  private let count: Int
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(count: Int) { self.count = count }

  func arrive() async {
    guard waiting.count + 1 >= count else {
      await withCheckedContinuation { waiting.append($0) }
      return
    }
    for task in waiting { task.resume() }
    waiting = []
  }
}
