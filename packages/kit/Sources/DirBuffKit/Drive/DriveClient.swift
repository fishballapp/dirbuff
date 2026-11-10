import CryptoKit
import Foundation

/// Drive over HTTPS (API v3) with the `drive.file` token of `GoogleSignIn`.
public struct DriveClient: DriveFiles {
  /// How an upload goes: one request up to `multipartLimit`, in `chunkSize` pieces above it.
  public struct UploadPolicy: Sendable, Equatable {
    public static let standard = UploadPolicy(multipartLimit: 5_000_000, chunkSize: 16 << 20)

    /// Google wants each chunk but the last to be a multiple of 256 KiB.
    static let chunkQuantum = 256 << 10

    public var multipartLimit: Int
    public var chunkSize: Int

    public init(multipartLimit: Int, chunkSize: Int) {
      self.multipartLimit = multipartLimit
      self.chunkSize = max(1, chunkSize / Self.chunkQuantum) * Self.chunkQuantum
    }
  }

  let transport: DriveTransport
  let uploads: UploadPolicy

  public init(
    tokens: any DriveAccessTokens, session: URLSession = .shared,
    uploads: UploadPolicy = .standard
  ) {
    self.init(
      tokens: tokens, session: session, uploads: uploads, pause: { try await Task.sleep(for: $0) })
  }

  init(
    tokens: any DriveAccessTokens, session: URLSession, uploads: UploadPolicy,
    pause: @escaping @Sendable (Duration) async throws -> Void
  ) {
    transport = DriveTransport(session: session, tokens: tokens, pause: pause)
    self.uploads = uploads
  }

  static let api = URL(constant: "https://www.googleapis.com/drive/v3")
  static let uploadAPI = URL(constant: "https://www.googleapis.com/upload/drive/v3/files")
  static let maxPageSize = 1000

  // MARK: Reading

  public func about() async throws -> DriveAbout {
    try await json(.get, "about", query: ["fields": DriveAbout.fields])
  }

  public func children(of folder: DriveFileID, after pageToken: String?) async throws -> DrivePage {
    try await list(
      query: "'\(Self.escaped(folder.rawValue))' in parents and trashed = false", pageToken)
  }

  public func created(after pageToken: String?) async throws -> DrivePage {
    try await list(query: "trashed = false", pageToken)
  }

  public func metadata(of id: DriveFileID) async throws -> DriveItem {
    try await json(.get, "files/\(id)", query: ["fields": DriveItem.fields])
  }

  public func download(_ id: DriveFileID, range: Range<Int64>?) async throws -> Data {
    var request = try Self.request(.get, "files/\(id)", query: ["alt": "media"])
    if let range {
      guard !range.isEmpty else { return Data() }
      request.setValue(
        "bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
    }
    let reply = try await transport.send(request)
    guard let range, reply.status == 200 else { return reply.data }
    // Google ignored the range and sent the whole file.
    let bytes = reply.data
    return bytes.dropFirst(Int(range.lowerBound)).prefix(Int(range.count))
  }

  // MARK: Changing

  public func createFolder(named name: String, in parent: DriveFileID?) async throws -> DriveItem {
    try await json(
      .post, "files", query: ["fields": DriveItem.fields],
      body: FileMetadata(
        name: name, parents: parent.map { [$0] }, mimeType: DriveItem.folderMimeType))
  }

  public func delete(_ id: DriveFileID) async throws {
    _ = try await transport.send(Self.request(.delete, "files/\(id)"))
  }

  /// Drive v3 has no untrash method: a file leaves the Bin when its `trashed` flag is cleared.
  public func untrash(_ id: DriveFileID) async throws -> DriveItem {
    try await json(
      .patch, "files/\(id)", query: ["fields": DriveItem.fields], body: TrashedFlag(trashed: false))
  }

  public func upload(_ data: Data, named name: String, in folder: DriveFileID) async throws
    -> DriveItem
  {
    let metadata = FileMetadata(name: name, parents: [folder], mimeType: nil)
    let stored =
      data.count <= uploads.multipartLimit
      ? try await uploadInOneRequest(data, metadata)
      : try await uploadInChunks(data, metadata)
    return try await verify(stored, holds: data)
  }

  // MARK: Checksums

  /// Drive reports a checksum of what it kept; a file whose checksum isn't the one of the bytes
  /// sent is removed rather than left behind as a lie.
  private func verify(_ stored: DriveItem, holds data: Data) async throws -> DriveItem {
    let (sent, kept) =
      stored.sha256Checksum != nil
      ? (Self.hex(SHA256.hash(data: data)), stored.sha256Checksum)
      : (Self.hex(Insecure.MD5.hash(data: data)), stored.md5Checksum)
    guard kept?.lowercased() == sent else {
      try? await delete(stored.id)
      throw DriveProblem.checksumMismatch(sent: sent, stored: kept)
    }
    return stored
  }

  private static func hex(_ digest: some Sequence<UInt8>) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Requests

  struct FileMetadata: Encodable {
    var name: String
    var parents: [DriveFileID]?
    var mimeType: String?
  }

  private struct TrashedFlag: Encodable { var trashed: Bool }

  enum Method: String {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case put = "PUT"
    case delete = "DELETE"
  }

  static func request(
    _ method: Method, _ path: String, query: [String: String] = [:], body: (any Encodable)? = nil
  ) throws -> URLRequest {
    var components = URLComponents(url: api.appending(path: path), resolvingAgainstBaseURL: false)
    components?.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
    guard let url = components?.url else {
      throw DriveProblem.rejected(status: 0, reason: nil, message: "\(path) isn't a URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method.rawValue
    if let body {
      request.httpBody = try JSONEncoder().encode(body)
      request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  private func json<Reply: Decodable>(
    _ method: Method, _ path: String, query: [String: String] = [:], body: (any Encodable)? = nil
  ) async throws -> Reply {
    let request = try Self.request(method, path, query: query, body: body)
    return try Self.decode(Reply.self, from: try await transport.send(request))
  }

  static func decode<Reply: Decodable>(_ type: Reply.Type, from reply: DriveTransport.Reply) throws
    -> Reply
  {
    do {
      return try JSONDecoder().decode(type, from: reply.data)
    } catch {
      throw DriveProblem.rejected(
        status: reply.status, reason: nil, message: "Google's reply wasn't readable")
    }
  }

  private func list(query: String, _ pageToken: String?) async throws -> DrivePage {
    try await json(
      .get, "files",
      query: [
        "q": query, "pageSize": String(Self.maxPageSize),
        "fields": "nextPageToken,files(\(DriveItem.fields))",
      ].merging(pageToken.map { ["pageToken": $0] } ?? [:]) { $1 })
  }

  /// Inside a Drive query's quotes, `\` and `'` need a backslash.
  private static func escaped(_ value: String) -> String {
    value.replacing("\\", with: "\\\\").replacing("'", with: "\\'")
  }
}
