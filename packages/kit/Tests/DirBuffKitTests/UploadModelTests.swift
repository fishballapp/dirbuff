import CryptoKit
import Foundation
import Testing

@testable import DirBuffKit

/// A backup through the pinned restic, the bridge and a real `DriveClient`, against a Drive that
/// answers each upload request after the latencies measured on a real account (Nov 2026): 5.2 s
/// to start a session, 1.8 s for any other request, and 1.12 MB/s of upload. It prints how fast
/// the backup went under two models of where the 1.12 MB/s limit sits: on each request (a cap per
/// connection or per upload, which more connections beat), or on the whole link (a cap per
/// account, which only hiding round trips helps). It proves nothing about Google; it shows what
/// round trips and connections cost. It also prints the peak memory of this process during the
/// backup (the bridge and `DriveClient`; the modelled Drive keeps no pack's bytes) and of restic.
/// Minutes long, so it runs only with DIRBUFF_UPLOAD_MODEL=1, one shape at a time, since restic's
/// peak is the largest of every restic this process has run:
///
/// ```sh
/// DIRBUFF_UPLOAD_MODEL=1 swift test --filter UploadModelTests/now
/// DIRBUFF_UPLOAD_MODEL=1 swift test --filter UploadModelTests/before
/// ```
@Suite(
  .serialized, .enabled(if: ProcessInfo.processInfo.environment["DIRBUFF_UPLOAD_MODEL"] == "1"))
struct UploadModelTests {
  /// Time runs this many times faster than modelled; restic's own work is counted at the same
  /// rate, so a larger number flatters it less accurately.
  static let speedUp = 2.0
  static let backupBytes = 200_000_000

  @Test(arguments: [false, true])
  func before(sharedLink: Bool) async throws {
    try await measure(
      "16 MiB chunks, 2 connections, one session", chunkSize: 16 << 20, connections: 2,
      lanes: 1, sharedLink: sharedLink)
  }

  @Test(arguments: [false, true])
  func now(sharedLink: Bool) async throws {
    let policy = DriveClient.UploadPolicy.standard
    try await measure(
      "a pack in one request, 4 connections, 4 sessions", chunkSize: policy.chunkSize,
      connections: DriveBridge.connections, lanes: policy.connections, sharedLink: sharedLink)
  }

  private func measure(
    _ label: String, chunkSize: Int, connections: Int, lanes: Int, sharedLink: Bool
  ) async throws {
    let model = ModelledDrive(sharedLink: sharedLink, speedUp: Self.speedUp)
    let fixture = try await BridgeFixture()
    var bridge = fixture.bridge
    bridge.connections = connections
    _ = try await bridge.serving(fixture.restic) { try await $0.createRepository() }
    let client = DriveClient(
      tokens: FixedTokens(), session: model.session,
      uploads: .init(multipartLimit: 5_000_000, chunkSize: chunkSize, connections: lanes),
      pause: { _ in })
    // Uploads go through the client and its modelled network, then into the in-memory Drive
    // for the bridge's reads: whole for the small files restic reads back (locks), empty for
    // packs, which a backup never reads, so the Drive holds no pack in memory.
    bridge.drive = InterceptedDrive(kept: fixture.drive) {
      [kept = fixture.drive] data, name, folder in
      _ = try await client.upload(data, named: name, in: folder)
      let keeps = data.count <= 5_000_000
      return try await kept.upload(keeps ? data : Data(), named: name, in: folder)
    }
    let source = try Self.randomFile(bytes: Self.backupBytes, in: fixture.scratch)

    let baseline = Self.footprint()
    let peak = Locked(baseline)
    let sampling = Task {
      while !Task.isCancelled {
        let now = Self.footprint()
        peak.withValue { $0 = max($0, now) }
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    let started = Date()
    _ = try await bridge.serving(fixture.restic) {
      try await $0.backup(source, tags: ["folder=model"], host: "model")
    }
    let seconds = Date().timeIntervalSince(started) * Self.speedUp
    sampling.cancel()
    var children = rusage()
    getrusage(RUSAGE_CHILDREN, &children)
    let log = model.log.withValue { $0 }
    print(
      String(
        format: "Upload model, %@, limit %@: %.0f s for %.0f MB, %.2f MB/s; %d session starts, "
          + "%d chunk requests, %d requests, at most %d at once; this process %.0f MB at "
          + "peak (%.0f MB above its %.0f MB before), restic %.0f MB at peak",
        label, sharedLink ? "on the link" : "per request", seconds, Double(log.bytes) / 1e6,
        Double(log.bytes) / 1e6 / seconds, log.sessionStarts, log.chunks, log.requests,
        log.mostAtOnce, Double(peak.withValue { $0 }) / 1e6,
        Double(peak.withValue { $0 } - baseline) / 1e6, Double(baseline) / 1e6,
        Double(children.ru_maxrss) / 1e6))
  }

  /// A folder holding one file of random bytes, written a piece at a time so making it doesn't
  /// count towards the peak.
  private static func randomFile(bytes: Int, in scratch: Scratch) throws -> URL {
    let folder = try scratch.folder("source")
    let file = folder.appendingPathComponent("noise.raw")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    var piece = Data(count: 8 << 20)
    for start in stride(from: 0, to: bytes, by: piece.count) {
      piece.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
      try handle.write(contentsOf: piece.prefix(min(piece.count, bytes - start)))
    }
    return folder
  }

  /// This process's memory as Activity Monitor counts it (`phys_footprint`), in bytes.
  private static func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }
}

/// Drive's upload endpoints, answering after the modelled time. Unlike `StubNetwork`, a reply
/// is scheduled rather than waited for, so requests overlap as they would on the wire.
private final class ModelledDrive: Sendable {
  static let sessionStart = 5.2
  static let otherRequest = 1.8
  static let bytesPerSecond = 1.12e6

  struct Log {
    var requests = 0
    var sessionStarts = 0
    var chunks = 0
    var bytes = 0
    var atOnce = 0
    var mostAtOnce = 0
  }

  let sharedLink: Bool
  let speedUp: Double
  let log = Locked(Log())
  /// Each session's bytes so far, as a running hash and a count: the bytes aren't kept.
  private let sessions = Locked<[(hash: SHA256, count: Int)]>([])
  private let linkFreeAt = Locked(Date.distantPast)
  private let id = UUID().uuidString

  init(sharedLink: Bool, speedUp: Double) {
    self.sharedLink = sharedLink
    self.speedUp = speedUp
    ModelledNetwork.drives.withValue { $0[id] = self }
  }

  var session: URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ModelledNetwork.self]
    configuration.httpAdditionalHeaders = [ModelledNetwork.header: id]
    return URLSession(configuration: configuration)
  }

  /// The reply to `request`, and how many seconds of the model it takes. A chunk's bytes are
  /// hashed a piece at a time as they are read, so the model holds no copy of a pack.
  func answer(_ request: URLRequest) -> (StubReply, seconds: Double) {
    let query =
      (request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
      .queryItems ?? []).reduce(into: [String: String]()) { $0[$1.name] = $1.value }
    let isStart = query["uploadType"] == "resumable"
    let reply: StubReply
    var bytes = 0
    if isStart {
      let id = sessions.withValue {
        $0.append((SHA256(), 0))
        return $0.count - 1
      }
      reply = .reply(
        200,
        headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=\(id)"])
    } else if let id = query["upload_id"].flatMap({ Int($0) }) {
      let total = request.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last
        .flatMap { Int($0) }
      Self.forEachPiece(of: request) { piece in
        bytes += piece.count
        sessions.withValue {
          $0[id].hash.update(data: piece)
          $0[id].count += piece.count
        }
      }
      let received = sessions.withValue { $0[id] }
      reply =
        received.count < (total ?? 0)
        ? .reply(308, headers: ["Range": "bytes=0-\(received.count - 1)"])
        : Self.stored(received.hash.finalize(), size: received.count)
    } else {
      // Multipart: a small file, read whole.
      var body = Data()
      Self.forEachPiece(of: request) { body.append($0) }
      bytes = body.count
      let media = Self.media(ofMultipart: body)
      reply = Self.stored(SHA256.hash(data: media), size: media.count)
    }
    log.withValue {
      $0.requests += 1
      $0.sessionStarts += isStart ? 1 : 0
      $0.chunks += query["upload_id"] == nil ? 0 : 1
      $0.bytes += bytes
    }
    return (reply, seconds: (isStart ? Self.sessionStart : Self.otherRequest) + sending(bytes))
  }

  /// Seconds until `bytes` are sent: alone at the full rate, or behind what the link already
  /// carries.
  private func sending(_ bytes: Int) -> Double {
    let seconds = Double(bytes) / Self.bytesPerSecond
    guard sharedLink else { return seconds }
    return linkFreeAt.withValue { freeAt in
      let now = Date()
      freeAt = max(now, freeAt).addingTimeInterval(seconds / speedUp)
      return freeAt.timeIntervalSince(now) * speedUp
    }
  }

  /// The request's body, a piece at a time.
  private static func forEachPiece(of request: URLRequest, _ body: (Data) -> Void) {
    if let whole = request.httpBody {
      body(whole)
      return
    }
    guard let stream = request.httpBodyStream else { return }
    stream.open()
    defer { stream.close() }
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
      body(Data(buffer[0..<count]))
    }
  }

  private static func stored(_ digest: SHA256.Digest, size: Int) -> StubReply {
    let sha = digest.map { String(format: "%02x", $0) }.joined()
    return .json(200, itemJSON("f-\(UUID().uuidString)", size: size, sha256: sha))
  }

  /// The file's bytes in a multipart body: after the second part's headers, before the last
  /// boundary.
  private static func media(ofMultipart body: Data) -> Data {
    let start = body.firstRange(of: Data("octet-stream\r\n\r\n".utf8))?.upperBound ?? 0
    let end = body.range(of: Data("\r\n--".utf8), options: .backwards)?.lowerBound ?? body.endIndex
    return body[start..<max(start, end)]
  }
}

private final class ModelledNetwork: URLProtocol, @unchecked Sendable {
  static let header = "X-Modelled-Drive"
  static let drives = Locked<[String: ModelledDrive]>([:])

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let headers = request.allHTTPHeaderFields ?? [:]
    guard let id = headers[Self.header], let drive = Self.drives.withValue({ $0[id] }),
      let url = request.url
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let (reply, seconds) = drive.answer(request)
    drive.log.withValue {
      $0.atOnce += 1
      $0.mostAtOnce = max($0.mostAtOnce, $0.atOnce)
    }
    let client = client
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds / drive.speedUp) {
      drive.log.withValue { $0.atOnce -= 1 }
      guard case .reply(let status, let replyHeaders, let body) = reply,
        let response = HTTPURLResponse(
          url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: replyHeaders)
      else { return }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }
}
