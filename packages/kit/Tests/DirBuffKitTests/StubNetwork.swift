import DirBuffKit
import Foundation

/// Runs `body` under a lock, for state a stub's handler shares with its test.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return body(&value)
  }
}

extension Locked where Value == Int {
  /// Adds one and returns the new count.
  func increment() -> Int {
    withValue { count in
      count += 1
      return count
    }
  }
}

/// A request as a stub sees it.
struct StubRequest: Sendable {
  var method: String
  var url: URL
  var headers: [String: String]
  var body: Data

  var query: [String: String] {
    (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).reduce(into: [:]) {
      $0[$1.name] = $1.value
    }
  }
  func header(_ name: String) -> String? {
    headers.first { $0.key.lowercased() == name.lowercased() }?.value
  }
  var json: [String: Any] {
    (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
  }
}

enum StubReply: Sendable {
  case reply(Int, headers: [String: String] = [:], body: Data = Data())
  case failure(URLError.Code)

  static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> StubReply {
    .reply(status, headers: headers, body: Data(text.utf8))
  }
}

/// Stands in for the network: each session made by `StubNetwork.session` answers through its own
/// handler, so tests running side by side don't see each other's requests.
final class StubNetwork: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (StubRequest) -> StubReply

  private static let handlers = Locked<[String: Handler]>([:])
  private static let header = "X-Stub-Network"

  static func session(_ handler: @escaping Handler) -> URLSession {
    let id = UUID().uuidString
    handlers.withValue { $0[id] = handler }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubNetwork.self]
    configuration.httpAdditionalHeaders = [header: id]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let headers = request.allHTTPHeaderFields ?? [:]
    guard let id = headers[Self.header], let handler = Self.handlers.withValue({ $0[id] }),
      let url = request.url
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    let stubbed = StubRequest(
      method: request.httpMethod ?? "GET", url: url,
      headers: headers.filter { $0.key != Self.header }, body: Self.body(of: request))
    switch handler(stubbed) {
    case .failure(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case .reply(let status, let replyHeaders, let body):
      if let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: replyHeaders)
      {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      }
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  private static func body(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
      data.append(buffer, count: count)
    }
    return data
  }
}

/// A token source that never expires.
struct FixedTokens: DriveAccessTokens {
  var token = "access-1"
  func accessToken(forceRefresh: Bool) async throws -> String { token }
}
