import Foundation

/// A request of the HTTP/1.1 restic speaks to a REST server: a request line, headers, and a body.
struct HTTPRequest: Sendable {
  var method: String
  var path: String
  var query: [String: String]
  /// By lowercased name.
  var headers: [String: String]
  var body: Data

  var closesConnection: Bool { headers["connection"]?.lowercased() == "close" }
}

struct HTTPResponse: Sendable, Equatable {
  var status: Int
  var reason: String
  var headers: [String: String] = [:]
  var body = Data()
  /// What `Content-Length` says when it isn't the body's: a HEAD's answer names the file's size
  /// and sends no body.
  var contentLength: Int64?

  static let ok = HTTPResponse(status: 200, reason: "OK")
  static let badRequest = HTTPResponse(status: 400, reason: "Bad Request")
  static let notFound = HTTPResponse(status: 404, reason: "Not Found")
  static let methodNotAllowed = HTTPResponse(status: 405, reason: "Method Not Allowed")

  /// The status line, headers and body, as they go on the wire.
  var serialized: Data {
    let fields = headers.merging(["Content-Length": String(contentLength ?? Int64(body.count))]) {
      $1
    }
    let head =
      "HTTP/1.1 \(status) \(reason)\r\n"
      + fields.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
    return Data(head.utf8) + body
  }
}

/// Why a connection's bytes aren't a request this server takes.
enum HTTPReadError: Error {
  case malformed
  case tooLarge
}

/// Reads requests off one connected socket, in order.
struct HTTPConnection {
  /// A head larger than this isn't restic's.
  static let maxHeadBytes = 64 << 10
  /// restic's largest pack is 128 MiB.
  static let maxBodyBytes = 130 << 20
  private static let lineEnd = Data("\r\n".utf8)

  let socket: Int32
  private var buffer = Data()

  init(socket: Int32) {
    self.socket = socket
  }

  /// The next request, or nil once the other end has closed the connection between requests.
  mutating func nextRequest() async throws -> HTTPRequest? {
    guard let head = try await read(through: Self.lineEnd + Self.lineEnd, limit: Self.maxHeadBytes)
    else { return nil }
    var request = try Self.parseHead(head)
    request.body = try await readBody(framedBy: request.headers)
    return request
  }

  /// A body of `Content-Length` bytes, or in chunks (restic sends the empty body that creates a
  /// repository chunked).
  private mutating func readBody(framedBy headers: [String: String]) async throws -> Data {
    switch headers["transfer-encoding"]?.lowercased() {
    case nil:
      let length =
        try headers["content-length"].map { value in
          guard let length = Int(value), length >= 0 else { throw HTTPReadError.malformed }
          return length
        } ?? 0
      guard length <= Self.maxBodyBytes else { throw HTTPReadError.tooLarge }
      return try await read(count: length)
    case "chunked":
      var body = Data()
      while true {
        let sizeLine = try await requireLine()
        let size = String(decoding: sizeLine, as: UTF8.self).split(separator: ";").first
          .flatMap { Int($0.trimmingCharacters(in: .whitespaces), radix: 16) }
        guard let size, size >= 0 else { throw HTTPReadError.malformed }
        guard body.count + size <= Self.maxBodyBytes else { throw HTTPReadError.tooLarge }
        guard size > 0 else {
          // Trailers, up to the empty line that ends them.
          while try await !requireLine().isEmpty {}
          return body
        }
        body.append(try await read(count: size))
        guard try await requireLine().isEmpty else { throw HTTPReadError.malformed }
      }
    default:
      throw HTTPReadError.malformed
    }
  }

  private mutating func requireLine() async throws -> Data {
    guard let line = try await read(through: Self.lineEnd, limit: Self.maxHeadBytes) else {
      throw HTTPReadError.malformed
    }
    return line
  }

  /// The bytes before `delimiter`, taking both off the buffer; nil when the connection closed
  /// before any byte of them.
  private mutating func read(through delimiter: Data, limit: Int) async throws -> Data? {
    while true {
      if let found = buffer.firstRange(of: delimiter) {
        let bytes = Data(buffer[buffer.startIndex..<found.lowerBound])
        buffer = Data(buffer[found.upperBound...])
        return bytes
      }
      guard buffer.count <= limit else { throw HTTPReadError.tooLarge }
      guard try await readMore() else {
        if buffer.isEmpty { return nil }
        throw HTTPReadError.malformed
      }
    }
  }

  private mutating func read(count: Int) async throws -> Data {
    buffer.reserveCapacity(count)
    while buffer.count < count {
      guard try await readMore() else { throw HTTPReadError.malformed }
    }
    let bytes = Data(buffer.prefix(count))
    buffer = Data(buffer.dropFirst(count))
    return bytes
  }

  private static func parseHead(_ head: Data) throws -> HTTPRequest {
    let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
    let requestLine = lines.first?.split(separator: " ") ?? []
    guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
      let target = URLComponents(string: String(requestLine[1]))
    else { throw HTTPReadError.malformed }
    let headers = try lines.dropFirst().map { line in
      guard let colon = line.firstIndex(of: ":") else { throw HTTPReadError.malformed }
      return (
        line[..<colon].lowercased(),
        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      )
    }
    return HTTPRequest(
      method: String(requestLine[0]),
      path: target.path,
      query: Dictionary(
        (target.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 }),
      headers: Dictionary(headers, uniquingKeysWith: { $1 }),
      body: Data())
  }

  /// Reads what has arrived; false once the other end has closed.
  private mutating func readMore() async throws -> Bool {
    let chunk = try await Self.read(socket)
    buffer.append(chunk)
    return !chunk.isEmpty
  }

  // MARK: Blocking calls, off Swift's own threads

  /// The socket is blocking, so each call waits on a dispatch thread rather than holding one of
  /// the few that run Swift's tasks.
  private static func read(_ socket: Int32) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        var chunk = Data(count: 1 << 20)
        let count = chunk.withUnsafeMutableBytes { buffer in
          var count: Int
          repeat {
            count = Darwin.read(socket, buffer.baseAddress, buffer.count)
          } while count < 0 && errno == EINTR
          return count
        }
        guard count >= 0 else {
          continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
          return
        }
        continuation.resume(returning: chunk.prefix(count))
      }
    }
  }

  static func write(_ response: HTTPResponse, to socket: Int32) async throws {
    let bytes = response.serialized
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      DispatchQueue.global(qos: .utility).async {
        let failure = bytes.withUnsafeBytes { raw -> POSIXError? in
          var offset = 0
          while offset < raw.count {
            let written = Darwin.write(
              socket, raw.baseAddress?.advanced(by: offset), raw.count - offset)
            guard written >= 0 else {
              if errno == EINTR { continue }
              return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += written
          }
          return nil
        }
        if let failure {
          continuation.resume(throwing: failure)
        } else {
          continuation.resume()
        }
      }
    }
  }
}
