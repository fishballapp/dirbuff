import Foundation

/// How restic reaches a repository in Google Drive: a restic REST server (protocol v2) on a unix
/// socket, over `DriveFiles`. The repository on Drive has restic's own local layout, so a
/// downloaded copy opens with stock restic.
///
/// A bridge serves one restic command and stops when it ends (`serving`), so nothing that talks
/// to Drive outlives a command. Between commands it keeps two things in the store: the ID table,
/// each of the repository's files by path with its Drive ID (Drive allows duplicate names, so
/// nothing is looked up by name, and listings come from the table), and the uploads of the last
/// 24 hours, counted against the daily limit.
public struct DriveBridge: Sendable {
  /// Google lets an account upload 750 GB a day; the bridge pauses short of it.
  public static let defaultDailyUploadLimit: Int64 = 700_000_000_000
  /// Long enough for a 64 MiB pack to reach Drive on a slow uplink. The bridge answers a write
  /// only once Drive has it, and restic would otherwise give up on the request after 5 minutes;
  /// a Drive request that stalls fails on its own, sooner.
  public static let stuckRequestTimeout = Duration.seconds(3600)
  /// The bridge holds each write in memory until Drive has it: two at once is two packs (128 MiB
  /// at `--pack-size 64`), and enough to keep an uplink busy.
  public static let connections = 2
  static let uploadWindow: TimeInterval = 86_400

  public var drive: any DriveFiles
  public var store: Store
  /// The repository's folder in Drive (`DirBuff Backup/<Mac name>`).
  public var repository: DriveFileID
  var dailyUploadLimit: Int64
  var now: @Sendable () -> Date

  public init(drive: any DriveFiles, store: Store, repository: DriveFileID) {
    self.init(
      drive: drive, store: store, repository: repository,
      dailyUploadLimit: Self.defaultDailyUploadLimit, now: { Date() })
  }

  init(
    drive: any DriveFiles, store: Store, repository: DriveFileID, dailyUploadLimit: Int64,
    now: @escaping @Sendable () -> Date
  ) {
    self.drive = drive
    self.store = store
    self.repository = repository
    self.dailyUploadLimit = dailyUploadLimit
    self.now = now
  }

  /// Serves the repository while `body` runs one restic command, given `restic` pointed at the
  /// bridge, then stops. When the command fails because of Drive, this throws that as a
  /// `BridgeFailure` rather than restic's own failure.
  ///
  /// ```swift
  /// let result = try await bridge.serving(restic) { restic in try await restic.backup([folder]) }
  /// ```
  public func serving<Value>(_ restic: Restic, _ body: (Restic) async throws -> Value)
    async throws -> Value
  {
    let folder = try Self.makePrivateFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let listener = try UnixSocketListener(path: folder + "/restic.sock")
    let server = BridgeServer(self)
    async let served: Void = server.serve(listener)

    var restic = restic
    restic.repository = "rest:http+unix://\(listener.path):/"
    restic.stuckRequestTimeout = Self.stuckRequestTimeout
    restic.restConnections = Self.connections
    let outcome: Result<Value, any Error>
    do {
      outcome = .success(try await body(restic))
    } catch {
      outcome = .failure(error)
    }
    listener.stop()
    await served

    if case .failure(let error) = outcome, !Self.isStopped(error),
      let failure = await server.failure
    {
      throw failure
    }
    return try outcome.get()
  }

  /// Whether the command ended because it was stopped, not because Drive failed it.
  private static func isStopped(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if case ResticFailure.stalled = error { return true }
    return false
  }

  /// Replaces the ID table with what Drive holds now, from a fresh listing of every file this
  /// app created: the table otherwise only knows what the bridge wrote and deleted, so a file
  /// lost in Drive would go on being listed.
  public func rebuildTable() async throws {
    let items = try await drive.allCreated()
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    // The item's path below the repository's folder, or nil when it isn't in it. The layout is
    // at most three deep (`data/ab/<name>`).
    func path(of item: DriveItem, depth: Int = 0) -> String? {
      guard depth < 3, let parent = item.parents.first else { return nil }
      if parent == repository { return item.name }
      guard let folder = byID[parent], let above = path(of: folder, depth: depth + 1) else {
        return nil
      }
      return above + "/" + item.name
    }
    let found = items.compactMap { item in
      path(of: item).map {
        RepositoryFile(path: $0, driveID: item.id, size: item.isFolder ? nil : item.size ?? 0)
      }
    }
    // A folder made twice (a create whose reply was lost) is kept once, as the copy that holds
    // things, so new files go where the old ones are and a shard never splits in two.
    let childCounts = Dictionary(grouping: items.compactMap(\.parents.first), by: { $0 })
      .mapValues(\.count)
    let folders = Dictionary(grouping: found.filter(\.isFolder), by: \.path).values.compactMap {
      copies in
      copies.sorted { $0.driveID.rawValue < $1.driveID.rawValue }
        .max { childCounts[$0.driveID, default: 0] < childCounts[$1.driveID, default: 0] }
    }
    try store.replaceRepositoryFiles(in: repository, with: found.filter { !$0.isFolder } + folders)
  }

  /// When an upload of `size` bytes may go, given the uploads of the last day: nil for now, or
  /// the moment enough of them are a day old for it to fit under `limit`.
  static func resumption(of size: Int64, after uploads: [DriveUpload], limit: Int64, now: Date)
    -> Date?
  {
    var total = uploads.reduce(size) { $0 + $1.bytes }
    guard total > limit else { return nil }
    for upload in uploads {
      total -= upload.bytes
      if total <= limit { return upload.at.addingTimeInterval(uploadWindow) }
    }
    return now.addingTimeInterval(uploadWindow)
  }

  /// A new folder under the temporary directory that only this user can open, for the socket.
  /// A unix socket's path must fit in 104 bytes, so the name is short.
  private static func makePrivateFolder() throws -> String {
    var template = Array((NSTemporaryDirectory() + "dirbuff-bridge-XXXXXX").utf8CString)
    guard let made = mkdtemp(&template) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return String(cString: made)
  }
}
