import Foundation

/// Where Drive requests get their bearer token. `GoogleSignIn` is the real one.
public protocol DriveAccessTokens: Sendable {
  /// A token that's good now. With `forceRefresh`, one Google has just refused is replaced even
  /// if its clock says it's still good. Throws `DriveProblem.signedOut` when there's no way to
  /// get one without the user.
  func accessToken(forceRefresh: Bool) async throws -> String
}

/// Sends one request to Google with a token, and decides what each kind of failure means: a
/// refused token is replaced once, rate limits and Google's own errors are waited out with a
/// growing pause, and everything else is a `DriveProblem`.
struct DriveTransport: Sendable {
  struct Reply {
    var data: Data
    var status: Int
    var headers: HTTPURLResponse
  }

  static let maxRetries = 8
  static let longestPause = 64

  var session: URLSession
  var tokens: any DriveAccessTokens
  var pause: @Sendable (Duration) async throws -> Void

  /// 2ⁿ seconds for the nth retry, at most 64, and up to a second more so many clients
  /// that failed together don't come back together.
  static func backoff(retry: Int) -> Duration {
    .seconds(min(longestPause, 1 << retry)) + .milliseconds(Int.random(in: 0..<1000))
  }

  /// The reply to `request`, once it's a success or one of the `passing` statuses. A redirect is
  /// followed unless `followsRedirects` is false (a resumable upload's 308 means "go on", not
  /// "go elsewhere").
  func send(
    _ request: URLRequest, passing extra: Set<Int> = [], followsRedirects: Bool = true
  ) async throws -> Reply {
    var request = request
    var retries = 0
    var isTokenRefused = false
    while true {
      let token = try await tokens.accessToken(forceRefresh: isTokenRefused)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      let reply = try await perform(request, followsRedirects: followsRedirects)

      if (200..<300).contains(reply.status) || extra.contains(reply.status) { return reply }
      if reply.status == 401 {
        guard !isTokenRefused else { throw DriveProblem.signedOut }
        isTokenRefused = true
        continue
      }
      if let problem = DriveProblem.classify(status: reply.status, data: reply.data) {
        throw problem
      }
      guard retries < Self.maxRetries else {
        throw reply.status >= 500 ? DriveProblem.unreachable : DriveProblem.rateLimited
      }
      try await pause(Self.backoff(retry: retries))
      retries += 1
    }
  }

  private func perform(_ request: URLRequest, followsRedirects: Bool) async throws -> Reply {
    do {
      let (data, response) = try await session.data(
        for: request, delegate: followsRedirects ? nil : StopsAtRedirects())
      guard let http = response as? HTTPURLResponse else { throw DriveProblem.unreachable }
      return Reply(data: data, status: http.statusCode, headers: http)
    } catch let problem as DriveProblem {
      throw problem
    } catch {
      try Task.checkCancellation()
      throw DriveProblem.unreachable
    }
  }
}

private final class StopsAtRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
