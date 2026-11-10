import Foundation

/// A unix socket that accepts connections until it is stopped. Each accepted connection is a
/// blocking socket, handed out once through `connections`; whoever takes it closes it with
/// `close(_:)`, and `stop()` shuts down any still open, so a read waiting on one returns.
final class UnixSocketListener: @unchecked Sendable {
  let path: String
  let connections: AsyncStream<Int32>

  private let socket: Int32
  private let source: DispatchSourceRead
  private let continuation: AsyncStream<Int32>.Continuation
  private let lock = NSLock()
  private var open: Set<Int32> = []
  private var isStopped = false

  init(path: String) throws {
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { throw POSIXError(.ENAMETOOLONG) }
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: path.utf8)
    }

    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socket >= 0 else { throw POSIXError.current }
    let isBound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
      }
    }
    guard isBound, listen(socket, 16) == 0 else {
      let failure = POSIXError.current
      Darwin.close(socket)
      throw failure
    }
    // Not passed on to restic or any other child, and never waited on: accepted when ready.
    _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
    _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)

    let (connections, continuation) = AsyncStream.makeStream(of: Int32.self)
    self.path = path
    self.socket = socket
    self.connections = connections
    self.continuation = continuation
    source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .global(qos: .utility))
    source.setEventHandler { [self] in acceptWaiting() }
    source.setCancelHandler {
      Darwin.close(socket)
      unlink(path)
      continuation.finish()
    }
    source.resume()
  }

  /// Accepts no more connections and shuts down the open ones.
  func stop() {
    lock.withLock {
      isStopped = true
      for connection in open { shutdown(connection, SHUT_RDWR) }
    }
    source.cancel()
  }

  func close(_ connection: Int32) {
    _ = lock.withLock { open.remove(connection) }
    Darwin.close(connection)
  }

  private func acceptWaiting() {
    while true {
      let connection = accept(socket, nil, nil)
      guard connection >= 0 else { return }
      _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
      _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
      var isOn: Int32 = 1
      setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &isOn, socklen_t(MemoryLayout<Int32>.size))
      let isTaken = lock.withLock {
        guard !isStopped else { return false }
        open.insert(connection)
        return true
      }
      guard isTaken else {
        Darwin.close(connection)
        continue
      }
      continuation.yield(connection)
    }
  }
}

extension POSIXError {
  /// The error `errno` holds now.
  fileprivate static var current: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
