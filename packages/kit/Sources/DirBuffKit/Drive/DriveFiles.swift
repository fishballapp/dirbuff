import Foundation

/// What Backup asks of Google Drive, and nothing more. `DriveClient` is the real one; tests use
/// an in-memory one. Every call throws `DriveProblem` (or `CancellationError`).
///
/// Everything here sees only what this app created (`drive.file`), so a listing is never the
/// whole Drive. Names are not unique in Drive, so files are named by ID.
public protocol DriveFiles: Sendable {
  /// The account's address and its room.
  func about() async throws -> DriveAbout

  /// A folder in `parent`, or in My Drive when `parent` is nil.
  func createFolder(named name: String, in parent: DriveFileID?) async throws -> DriveItem

  /// One page of the folder's children that aren't in the Bin; pass the previous page's
  /// `nextPageToken` for the next.
  func children(of folder: DriveFileID, after pageToken: String?) async throws -> DrivePage

  /// One page of every file and folder this app created that isn't in the Bin.
  func created(after pageToken: String?) async throws -> DrivePage

  /// The file as Drive holds it now, in the Bin or not.
  func metadata(of id: DriveFileID) async throws -> DriveItem

  /// Creates a file in `folder` and returns it only once Drive's checksum of the stored bytes
  /// (SHA-256, else MD5) matches `data`'s: a returned file is durable. Throws
  /// `.checksumMismatch` otherwise, having removed the bad file. Never replaces a file: a retry
  /// after a lost reply can leave a second file of the same name, which is why files are named by
  /// ID.
  func upload(_ data: Data, named name: String, in folder: DriveFileID) async throws -> DriveItem

  /// The file's bytes, or those in `range` (the bytes before `range.upperBound`, clamped to the
  /// file's end).
  func download(_ id: DriveFileID, range: Range<Int64>?) async throws -> Data

  /// Deletes the file for good, skipping the Bin, which would go on counting against the account's
  /// storage.
  func delete(_ id: DriveFileID) async throws

  /// Takes the file out of the Bin.
  func untrash(_ id: DriveFileID) async throws -> DriveItem
}

extension DriveFiles {
  /// Every child of the folder, following the pages.
  public func allChildren(of folder: DriveFileID) async throws -> [DriveItem] {
    try await collect { try await children(of: folder, after: $0) }
  }

  /// Every file and folder this app created, following the pages.
  public func allCreated() async throws -> [DriveItem] {
    try await collect { try await created(after: $0) }
  }

  private func collect(_ page: (String?) async throws -> DrivePage) async throws -> [DriveItem] {
    var items: [DriveItem] = []
    var token: String?
    repeat {
      let next = try await page(token)
      items += next.items
      token = next.nextPageToken
    } while token != nil
    return items
  }
}
