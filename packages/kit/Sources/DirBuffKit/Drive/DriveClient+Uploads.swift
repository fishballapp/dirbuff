import Foundation

/// The two ways a file reaches Drive. A small one goes in a single multipart request. A large one
/// goes through a resumable session in chunks; a chunk that gets no answer is not guessed at: the
/// session is asked how much it has.
extension DriveClient {
  /// How many times in a row a session may fail to answer before the upload is given up.
  static let maxSilentFailures = 5
  /// How many times a session that expired may be replaced by a fresh one.
  static let maxSessions = 3

  // MARK: Multipart

  func uploadInOneRequest(_ data: Data, _ metadata: FileMetadata) async throws -> DriveItem {
    let boundary = "dirbuff-\(UUID().uuidString)"
    var body = Data()
    body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
    body.append(try JSONEncoder().encode(metadata))
    body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
    body.append(data)
    body.append(Data("\r\n--\(boundary)--".utf8))

    var request = try Self.uploadRequest(.post, query: ["uploadType": "multipart"])
    request.httpBody = body
    request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    return try Self.decode(DriveItem.self, from: try await transport.send(request))
  }

  // MARK: Resumable

  func uploadInChunks(_ data: Data, _ metadata: FileMetadata) async throws -> DriveItem {
    for _ in 0..<Self.maxSessions {
      let session = try await startSession(for: data.count, metadata)
      if let stored = try await transfer(data, to: session) { return stored }
    }
    throw DriveProblem.unreachable
  }

  private func startSession(for size: Int, _ metadata: FileMetadata) async throws -> URL {
    var request = try Self.uploadRequest(.post, query: ["uploadType": "resumable"])
    request.httpBody = try JSONEncoder().encode(metadata)
    request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    request.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
    request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
    let reply = try await transport.send(request)
    guard let location = reply.headers.value(forHTTPHeaderField: "Location").flatMap(URL.init)
    else {
      throw DriveProblem.rejected(
        status: reply.status, reason: nil, message: "Google gave no upload session")
    }
    return location
  }

  /// Sends `data` through the session. Returns the stored file, or nil when the session has
  /// expired and the upload has to start again.
  private func transfer(_ data: Data, to session: URL) async throws -> DriveItem? {
    var offset = 0
    var isAsking = false
    var silentFailures = 0
    while true {
      do {
        let reply =
          isAsking
          ? try await ask(session, size: data.count)
          : try await sendChunk(of: data, from: offset, to: session)
        switch reply.status {
        case 200, 201:
          return try Self.decode(DriveItem.self, from: reply)
        case 404:
          return nil
        default:
          let received = Self.bytesReceived(reply.headers)
          // A session that takes a whole chunk and still reports no more than before is
          // not going anywhere.
          if received > offset {
            silentFailures = 0
          } else if !isAsking {
            throw DriveProblem.unreachable
          }
          offset = received
          isAsking = false
        }
      } catch DriveProblem.unreachable {
        silentFailures += 1
        guard silentFailures <= Self.maxSilentFailures else { throw DriveProblem.unreachable }
        try await transport.pause(DriveTransport.backoff(retry: silentFailures - 1))
        isAsking = true
      }
    }
  }

  private func sendChunk(of data: Data, from offset: Int, to session: URL) async throws
    -> DriveTransport.Reply
  {
    let end = min(offset + uploads.chunkSize, data.count)
    var request = URLRequest(url: session)
    request.httpMethod = "PUT"
    request.httpBody = data[offset..<end]
    request.setValue(
      "bytes \(offset)-\(end - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
    return try await transport.send(request, passing: [308, 404], followsRedirects: false)
  }

  /// "Where did you get to?": an empty request whose range is unknown.
  private func ask(_ session: URL, size: Int) async throws -> DriveTransport.Reply {
    var request = URLRequest(url: session)
    request.httpMethod = "PUT"
    request.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
    return try await transport.send(request, passing: [308, 404], followsRedirects: false)
  }

  /// A 308's `Range: bytes=0-42` means the first 43 bytes are safe; no header means none are.
  private static func bytesReceived(_ response: HTTPURLResponse) -> Int {
    guard let last = response.value(forHTTPHeaderField: "Range")?.split(separator: "-").last,
      let lastByte = Int(last)
    else { return 0 }
    return lastByte + 1
  }

  static func uploadRequest(_ method: Method, query: [String: String]) throws -> URLRequest {
    var components = URLComponents(url: uploadAPI, resolvingAgainstBaseURL: false)
    components?.queryItems = query.merging(["fields": DriveItem.fields]) { $1 }
      .sorted { $0.key < $1.key }.map(URLQueryItem.init)
    guard let url = components?.url else {
      throw DriveProblem.rejected(status: 0, reason: nil, message: "Upload URL isn't a URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method.rawValue
    return request
  }
}
