import Foundation
import Testing

@testable import DirBuffKit

/// restic's connections to the bridge, when restic goes away mid-conversation: the bridge's answer
/// to a connection already closed must fail that send, never raise SIGPIPE, which would end the
/// app (and, here, the test process).
@Suite struct BridgeConnectionTests {
  private static let listing = Data("GET /locks/ HTTP/1.1\r\n\r\n".utf8)

  @Test func anAnswerToAClosedConnectionFailsWithoutASignal() async throws {
    var ends: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
    Darwin.close(ends[1])
    defer { Darwin.close(ends[0]) }

    await #expect(throws: POSIXError(.EPIPE)) {
      try await HTTPConnection.write(.ok, to: ends[0])
    }
  }

  @Test func clientsThatAskAndHangUpLeaveTheBridgeServingTheNext() async throws {
    let fixture = try await BridgeFixture()
    let folder = try Self.shortFolder()
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let listener = try UnixSocketListener(path: folder + "/restic.sock")
    let server = BridgeServer(fixture.bridge)
    async let served: Void = server.serve(listener)

    // Each asks and closes before the answer: often before the bridge has even accepted it.
    for _ in 0..<200 {
      try await Self.blocking {
        let client = try Self.connect(to: listener.path)
        defer { Darwin.close(client) }
        try Self.send(Self.listing, over: client)
      }
    }
    let answer = try await Self.blocking {
      let client = try Self.connect(to: listener.path)
      defer { Darwin.close(client) }
      try Self.send(Self.listing, over: client)
      return try Self.readHead(from: client)
    }

    listener.stop()
    await served
    #expect(answer.hasPrefix("HTTP/1.1 200 OK"))
  }

  // MARK: - A client

  /// A new folder under the temporary directory short enough for a socket's path (104 bytes).
  private static func shortFolder() throws -> String {
    var template = Array((NSTemporaryDirectory() + "dirbuff-conn-XXXXXX").utf8CString)
    guard let made = mkdtemp(&template) else { throw POSIXError.current }
    return String(cString: made)
  }

  /// Runs `body`, which blocks on sockets, on a dispatch thread rather than one of Swift's own.
  private static func blocking<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value)
    async throws -> Value
  {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(with: Result { try body() }) }
    }
  }

  /// Connects, trying again while the listener's queue of connections not yet accepted is full
  /// (`ECONNREFUSED`): these clients come faster than any restic's.
  private static func connect(to path: String) throws -> Int32 {
    let deadline = ContinuousClock.now + hangLimit
    while true {
      do {
        return try connectOnce(to: path)
      } catch POSIXError.ECONNREFUSED where ContinuousClock.now < deadline {
        usleep(1000)
      }
    }
  }

  private static func connectOnce(to path: String) throws -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    let client = socket(AF_UNIX, SOCK_STREAM, 0)
    guard client >= 0 else { throw POSIXError.current }
    let isConnected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
      }
    }
    guard isConnected else {
      let failure = POSIXError.current
      Darwin.close(client)
      throw failure
    }
    return client
  }

  private static func send(_ data: Data, over client: Int32) throws {
    let sent = data.withUnsafeBytes {
      Darwin.send(client, $0.baseAddress, $0.count, MSG_NOSIGNAL)
    }
    guard sent == data.count else { throw POSIXError.current }
  }

  /// What the bridge answered, up to the end of its head.
  private static func readHead(from client: Int32) throws -> String {
    var received = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while received.firstRange(of: Data("\r\n\r\n".utf8)) == nil {
      let count = read(client, &chunk, chunk.count)
      guard count > 0 else { throw POSIXError.current }
      received.append(contentsOf: chunk[0..<count])
    }
    return String(decoding: received, as: UTF8.self)
  }
}

extension POSIXError {
  fileprivate static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
