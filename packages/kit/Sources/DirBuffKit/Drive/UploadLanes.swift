import Foundation

/// A URLSession per connection that uploads go over, each upload on the least busy one. One
/// session sends every request to a host down one HTTP/2 or HTTP/3 connection, so uploads at the
/// same time would share one connection's congestion window, and one stall would hold up them
/// all; sessions don't share connections, so each lane gets its own. A session is made the first
/// time its lane is used, and all are let go with the lanes.
final class UploadLanes: @unchecked Sendable {
  private let configuration: URLSessionConfiguration
  private let lock = NSLock()
  private var sessions: [URLSession?]
  private var uploads: [Int]

  init(count: Int, configuration: URLSessionConfiguration) {
    self.configuration = configuration
    sessions = Array(repeating: nil, count: max(1, count))
    uploads = Array(repeating: 0, count: max(1, count))
  }

  deinit {
    for session in sessions { session?.finishTasksAndInvalidate() }
  }

  /// Runs `body` with the session of the lane with the fewest uploads under way.
  func withLane<Value>(_ body: (URLSession) async throws -> Value) async throws -> Value {
    let (lane, session) = take()
    defer { lock.withLock { uploads[lane] -= 1 } }
    return try await body(session)
  }

  private func take() -> (Int, URLSession) {
    lock.withLock {
      let lane = uploads.indices.min { uploads[$0] < uploads[$1] } ?? 0
      let session = sessions[lane] ?? URLSession(configuration: configuration)
      sessions[lane] = session
      uploads[lane] += 1
      return (lane, session)
    }
  }
}
