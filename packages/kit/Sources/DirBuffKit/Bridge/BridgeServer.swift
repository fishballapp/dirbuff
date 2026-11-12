import Foundation

/// Answers one restic command's requests (the REST protocol, version 2) from the ID table and
/// Drive. Names and sizes come from the table, so only reading, writing and deleting bytes asks
/// Drive anything.
actor BridgeServer {
  private let bridge: DriveBridge
  /// The first of Drive's failures that stopped requests, which the caller is told of: the
  /// cause, where later ones are only its consequences.
  private(set) var failure: BridgeFailure?
  /// The failure that stopped each kind of request for the rest of the command.
  private var stoppedBy: [DriveUse: BridgeFailure] = [:]
  /// Folders being created, so two uploads into a new folder don't make two.
  private var folderCreations: [String: Task<DriveFileID, any Error>] = [:]
  /// Files being uploaded, so a retried write waits for the upload already under way.
  private var writes: [String: PendingWrite] = [:]

  private struct PendingWrite {
    var data: Data
    var upload: Task<Void, any Error>
  }

  init(_ bridge: DriveBridge) {
    self.bridge = bridge
  }

  private var drive: any DriveFiles { bridge.drive }
  private var store: Store { bridge.store }
  private var repository: DriveFileID { bridge.repository }

  // MARK: Connections

  /// Answers every connection `listener` accepts until it stops.
  nonisolated func serve(_ listener: UnixSocketListener) async {
    await withDiscardingTaskGroup { group in
      for await connection in listener.connections {
        group.addTask {
          await self.converse(over: connection)
          listener.close(connection)
        }
      }
    }
  }

  /// One request after another, as long as restic keeps the connection.
  private nonisolated func converse(over socket: Int32) async {
    var connection = HTTPConnection(socket: socket)
    while true {
      let response: HTTPResponse
      let isLast: Bool
      do {
        guard let request = try await connection.nextRequest() else { return }
        response = await respond(to: request)
        isLast = request.closesConnection
      } catch is HTTPReadError {
        response = .badRequest
        isLast = true
      } catch {
        return
      }
      do {
        try await HTTPConnection.write(response, to: socket)
      } catch {
        return
      }
      if isLast { return }
    }
  }

  // MARK: Routes

  func respond(to request: HTTPRequest) async -> HTTPResponse {
    do {
      return try await route(request)
    } catch let failure as BridgeFailure {
      return HTTPResponse(status: failure.status.code, reason: failure.status.reason)
    } catch DriveProblem.notFound {
      return .notFound
    } catch is CancellationError {
      return HTTPResponse(status: 503, reason: "Stopping")
    } catch {
      return HTTPResponse(status: 500, reason: "Internal Server Error")
    }
  }

  private func route(_ request: HTTPRequest) async throws -> HTTPResponse {
    // "/" is the repository; "/config" its config; "/keys/" a listing; "/keys/<name>" a file.
    let parts = request.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
      .map(String.init)
    if parts == [""] { return try await repositoryRoute(request) }
    if parts == [RepositoryLayout.config] {
      return try await fileRoute(request, path: RepositoryLayout.config)
    }
    guard parts.count == 2, let type = RepositoryLayout.FileType(rawValue: parts[0]) else {
      return .notFound
    }
    let name = parts[1]
    if name.isEmpty {
      guard request.method == "GET" else { return .methodNotAllowed }
      return try listing(of: type, accept: request.headers["accept"])
    }
    guard RepositoryLayout.isFileName(name) else { return .badRequest }
    return try await fileRoute(request, path: RepositoryLayout.path(of: type, named: name))
  }

  private func repositoryRoute(_ request: HTTPRequest) async throws -> HTTPResponse {
    switch request.method {
    case "POST" where request.query["create"] == "true":
      try await createFolders()
      return .ok
    // Deleting a backup is DirBuff's to do, never a REST client's.
    case "DELETE": return HTTPResponse(status: 501, reason: "Not Implemented")
    default: return .methodNotAllowed
    }
  }

  private func fileRoute(_ request: HTTPRequest, path: String) async throws -> HTTPResponse {
    switch request.method {
    case "HEAD":
      guard let file = try storedFile(at: path) else { return .notFound }
      return HTTPResponse(status: 200, reason: "OK", contentLength: file.size)
    case "GET": return try await read(path, range: request.headers["range"])
    case "POST": return try await write(request.body, to: path)
    case "DELETE": return try await delete(path)
    default: return .methodNotAllowed
    }
  }

  // MARK: Listing, reading, writing, deleting

  private func listing(of type: RepositoryLayout.FileType, accept: String?) throws -> HTTPResponse {
    let files = try store.repositoryFiles(in: repository, under: type.rawValue)
    let names = files.map { String($0.path.split(separator: "/").last ?? "") }
    guard accept?.contains(Self.version2) == true else {
      return HTTPResponse(status: 200, reason: "OK", body: try JSONEncoder().encode(names))
    }
    let entries = zip(names, files).map { ListedFile(name: $0, size: $1.size ?? 0) }
    return HTTPResponse(
      status: 200, reason: "OK", headers: ["Content-Type": Self.version2],
      body: try JSONEncoder().encode(entries))
  }

  private static let version2 = "application/vnd.x.restic.rest.v2"

  private struct ListedFile: Encodable {
    var name: String
    var size: Int64
  }

  private func read(_ path: String, range header: String?) async throws -> HTTPResponse {
    guard let file = try storedFile(at: path), let size = file.size else { return .notFound }
    guard let range = ByteRange(header, size: size) else {
      return HTTPResponse(
        status: 416, reason: "Range Not Satisfiable", headers: ["Content-Range": "bytes */\(size)"])
    }
    let bytes: Data
    if let contents = try await contents(of: file, at: path) {
      bytes = contents.subdata(in: Int(range.bounds.lowerBound)..<Int(range.bounds.upperBound))
    } else {
      bytes = try await calling(.read) { [drive] in
        try await drive.download(file.driveID, range: range.bounds)
      }
    }
    guard range.isPartial else { return HTTPResponse(status: 200, reason: "OK", body: bytes) }
    return HTTPResponse(
      status: 206, reason: "Partial Content",
      headers: [
        "Content-Range":
          "bytes \(range.bounds.lowerBound)-\(range.bounds.upperBound - 1)/\(size)"
      ], body: bytes)
  }

  /// The whole of a file the table keeps, from the table, or from Drive the first time.
  private func contents(of file: RepositoryFile, at path: String) async throws -> Data? {
    guard Self.isKept(path) else { return nil }
    if let contents = file.contents { return contents }
    let contents = try await calling(.read) { [drive] in
      try await drive.download(file.driveID, range: nil)
    }
    try store.keepContents(contents, of: file.driveID, in: repository)
    return contents
  }

  /// `config` and the keys: small, read by every command, and never changed.
  private static func isKept(_ path: String) -> Bool {
    path == RepositoryLayout.config || path.hasPrefix("keys/")
  }

  /// Answers only once Drive has the bytes and its checksum of them matches: restic orders its
  /// writes on the promise that a stored file is durable. A write restic retries (its reply was
  /// lost, or it timed out waiting) is answered by the file already stored or on its way, never
  /// uploaded twice.
  private func write(_ data: Data, to path: String) async throws -> HTTPResponse {
    if let pending = writes[path] {
      guard Self.isSame(data, as: pending.data, at: path) else { return Self.alreadyExists }
      try await pending.upload.value
      return .ok
    }
    if let stored = try storedFile(at: path) {
      return try await isSame(data, as: stored, at: path) ? .ok : Self.alreadyExists
    }
    let isLock = Self.isLock(path)
    if !isLock { try checkUploadAllowance(for: data.count) }
    let upload = Task { try await self.upload(data, to: path, isLock: isLock) }
    writes[path] = PendingWrite(data: data, upload: upload)
    defer { writes[path] = nil }
    try await upload.value
    return .ok
  }

  private func upload(_ data: Data, to path: String, isLock: Bool) async throws {
    let folder = try await folderID(at: Self.parent(of: path))
    let name = String(path.split(separator: "/").last ?? "")
    let stored = try await calling(isLock ? .bookkeeping : .upload) { [drive] in
      try await drive.upload(data, named: name, in: folder)
    }
    try store.record(
      RepositoryFile(
        path: path, driveID: stored.id, size: Int64(data.count),
        contents: Self.isKept(path) ? data : nil),
      in: repository)
    // Locks are a few hundred bytes, and must go up even when the day's uploads are spent.
    guard !isLock else { return }
    try store.recordUpload(
      DriveUpload(at: bridge.now(), bytes: Int64(data.count)), keeping: DriveBridge.uploadWindow)
  }

  /// Every file but `config` is named by its contents' hash, so the same name and size is the
  /// same file. `config` is compared byte for byte.
  private static func isSame(_ data: Data, as other: Data, at path: String) -> Bool {
    path == RepositoryLayout.config ? data == other : data.count == other.count
  }

  private func isSame(_ data: Data, as stored: RepositoryFile, at path: String) async throws
    -> Bool
  {
    guard path == RepositoryLayout.config else { return Int64(data.count) == stored.size }
    return try await contents(of: stored, at: path) == data
  }

  /// As restic's own REST server: a file is never replaced.
  private static let alreadyExists = HTTPResponse(status: 403, reason: "Already Exists")

  private static func isLock(_ path: String) -> Bool { path.hasPrefix("locks/") }

  private func delete(_ path: String) async throws -> HTTPResponse {
    let files = try store.repositoryFiles(in: repository, at: path)
    guard !files.isEmpty else { return .notFound }
    for file in files {
      try store.markRepositoryFileDeleting(file.driveID, in: repository)
      do {
        try await calling(.delete) { [drive] in try await drive.delete(file.driveID) }
      } catch DriveProblem.notFound {
        // Already gone, which is what was asked.
      }
      try store.forgetRepositoryFile(file.driveID, in: repository)
    }
    return .ok
  }

  private func storedFile(at path: String) throws -> RepositoryFile? {
    try store.repositoryFiles(in: repository, at: path).first { !$0.isFolder }
  }

  // MARK: Folders

  /// restic's local layout, every folder of it, so the repository on Drive is one stock restic
  /// opens from a download. Already there is fine.
  private func createFolders() async throws {
    let (types, shards) = (
      RepositoryLayout.folders.filter { !$0.contains("/") },
      RepositoryLayout.folders.filter { $0.contains("/") }
    )
    for folder in types { _ = try await folderID(at: folder) }
    // A few at a time: 256 one after another take a minute.
    for start in stride(from: 0, to: shards.count, by: Self.parallelFolderCreations) {
      try await withThrowingTaskGroup(of: DriveFileID.self) { group in
        for folder in shards[start..<min(start + Self.parallelFolderCreations, shards.count)] {
          group.addTask { try await self.folderID(at: folder) }
        }
        try await group.waitForAll()
      }
    }
  }

  private static let parallelFolderCreations = 8

  /// The folder's Drive ID, creating it, and the folders above it, when the table has none.
  private func folderID(at path: String) async throws -> DriveFileID {
    if path.isEmpty { return repository }
    if let known = try store.repositoryFiles(in: repository, at: path).first(where: \.isFolder) {
      return known.driveID
    }
    if let creation = folderCreations[path] { return try await creation.value }
    let creation = Task {
      let parent = try await folderID(at: Self.parent(of: path))
      let name = String(path.split(separator: "/").last ?? "")
      // A create whose reply was lost may have made it: use that one rather than a second.
      let existing = try await calling(.read) { [drive] in
        try await drive.allChildren(of: parent).first { $0.isFolder && $0.name == name }
      }
      let folder = try await {
        if let existing { return existing }
        return try await calling(.bookkeeping) { [drive] in
          try await drive.createFolder(named: name, in: parent)
        }
      }()
      try store.record(RepositoryFile(path: path, driveID: folder.id), in: repository)
      return folder.id
    }
    folderCreations[path] = creation
    defer { folderCreations[path] = nil }
    return try await creation.value
  }

  private static func parent(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
  }

  // MARK: Failures

  /// Runs a Drive call unless an earlier failure stopped calls of its kind, and turns Drive's
  /// problem into the failure the caller is told of. A read's or a delete's 404 is only an
  /// answer, so it passes through as it is.
  private func calling<Value: Sendable>(
    _ use: DriveUse, _ call: @Sendable () async throws -> Value
  ) async throws -> Value {
    if let failure = stoppedBy[use] { throw failure }
    do {
      return try await call()
    } catch let problem as DriveProblem {
      if problem == .notFound, use != .upload { throw problem }
      let failure =
        problem == .dailyUploadLimit
        ? BridgeFailure.uploadPaused(until: try googlesLimitLifts()) : .drive(problem)
      record(failure)
      throw failure
    }
  }

  /// Keeps a failure that stops requests. One that doesn't (a checksum mismatch, a refusal) is
  /// only that request's: restic retries it or fails on it, and says so itself.
  private func record(_ failure: BridgeFailure) {
    guard !failure.stops.isEmpty else { return }
    if self.failure == nil { self.failure = failure }
    for use in failure.stops where stoppedBy[use] == nil { stoppedBy[use] = failure }
  }

  /// Pauses before an upload that would take the last day's uploads, and those still on their
  /// way, past the limit.
  private func checkUploadAllowance(for size: Int) throws {
    if let failure = stoppedBy[.upload] { throw failure }
    let now = bridge.now()
    let uploads = try store.uploads(since: now.addingTimeInterval(-DriveBridge.uploadWindow))
    let underWay = writes.filter { !Self.isLock($0.key) }.values.reduce(0) { $0 + $1.data.count }
    guard
      let resumption = DriveBridge.resumption(
        of: Int64(size + underWay), after: uploads, limit: bridge.dailyUploadLimit, now: now)
    else { return }
    let failure = BridgeFailure.uploadPaused(until: resumption)
    record(failure)
    throw failure
  }

  /// When Google's own daily limit, counted over a rolling day, may let uploads through again:
  /// once the oldest upload it counted is a day old. Google counts uploads this bridge never saw,
  /// so this is a guess, and the next run tries again.
  private func googlesLimitLifts() throws -> Date {
    let now = bridge.now()
    let oldest = try store.uploads(since: now.addingTimeInterval(-DriveBridge.uploadWindow)).first
    return (oldest?.at ?? now).addingTimeInterval(DriveBridge.uploadWindow)
  }
}

/// A `Range: bytes=<first>-[<last>]` header, the only form restic sends, clamped to the file.
struct ByteRange: Equatable {
  var bounds: Range<Int64>
  /// Whether the answer is a 206 with only these bytes.
  var isPartial: Bool

  /// The whole file when there's no header; nil when the range starts past the end, or isn't
  /// one this server reads.
  init?(_ header: String?, size: Int64) {
    guard let header else {
      self.init(bounds: 0..<size, isPartial: false)
      return
    }
    guard header.hasPrefix("bytes=") else { return nil }
    let ends = header.dropFirst("bytes=".count).split(
      separator: "-", omittingEmptySubsequences: false)
    guard ends.count == 2, let first = Int64(ends[0]), first < size else { return nil }
    let last = ends[1].isEmpty ? size - 1 : Int64(ends[1])
    guard let last, last >= first else { return nil }
    self.init(bounds: first..<(min(last, size - 1) + 1), isPartial: true)
  }

  init(bounds: Range<Int64>, isPartial: Bool) {
    self.bounds = bounds
    self.isPartial = isPartial
  }
}
