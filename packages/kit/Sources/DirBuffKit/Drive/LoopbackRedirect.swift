import Foundation
import Network

/// The web server that catches Google's redirect: one listener on 127.0.0.1 at a port the system
/// picks, which takes the browser's first request for `/` and answers it with a "close this tab"
/// page. Anything else it is asked for (a favicon, a probe) gets a 404 and doesn't end the wait.
final class LoopbackRedirect: @unchecked Sendable {
  struct Unavailable: Error {}

  let port: UInt16
  private let listener: NWListener
  private let redirects: AsyncStream<[String: String]>

  private init(
    listener: NWListener, port: UInt16, redirects: AsyncStream<[String: String]>
  ) {
    self.listener = listener
    self.port = port
    self.redirects = redirects
  }

  var redirectURI: String { "http://127.0.0.1:\(port)" }

  static func start() async throws -> LoopbackRedirect {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)

    let (redirects, redirected) = AsyncStream.makeStream(
      of: [String: String].self, bufferingPolicy: .bufferingNewest(1))
    listener.newConnectionHandler = { serve($0, redirected) }

    let (states, stateChanged) = AsyncStream.makeStream(of: NWListener.State.self)
    listener.stateUpdateHandler = { stateChanged.yield($0) }
    listener.start(queue: .global())
    for await state in states {
      switch state {
      case .ready:
        guard let port = listener.port?.rawValue else { throw Unavailable() }
        listener.stateUpdateHandler = nil
        return LoopbackRedirect(listener: listener, port: port, redirects: redirects)
      case .failed, .cancelled:
        listener.cancel()
        throw Unavailable()
      default:
        continue
      }
    }
    // The states stop coming only when the waiting task is cancelled.
    listener.cancel()
    throw CancellationError()
  }

  /// The query of the redirect, or nil when nothing came within `timeout`. Throws
  /// `CancellationError` when the waiting task is cancelled.
  func parameters(within timeout: Duration) async throws -> [String: String]? {
    let redirects = redirects
    return try await withThrowingTaskGroup(of: [String: String]?.self) { group in
      group.addTask { await redirects.first { _ in true } }
      group.addTask {
        try await Task.sleep(for: timeout)
        return nil
      }
      defer { group.cancelAll() }
      let first = try await group.next() ?? nil
      try Task.checkCancellation()
      return first
    }
  }

  func close() {
    listener.cancel()
  }

  // MARK: One connection

  private static func serve(
    _ connection: NWConnection, _ redirected: AsyncStream<[String: String]>.Continuation
  ) {
    connection.start(queue: .global())
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
      guard let data, let parameters = redirectParameters(in: data) else {
        respond(to: connection, status: "404 Not Found", body: "")
        return
      }
      respond(to: connection, status: "200 OK", body: page)
      redirected.yield(parameters)
    }
  }

  /// The query of `GET /?…` when it carries Google's answer (a code or an error).
  private static func redirectParameters(in request: Data) -> [String: String]? {
    guard let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first else {
      return nil
    }
    let parts = line.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET",
      let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
      components.path == "/"
    else { return nil }
    let parameters = (components.queryItems ?? []).reduce(into: [String: String]()) {
      $0[$1.name] = $1.value
    }
    return parameters["code"] != nil || parameters["error"] != nil ? parameters : nil
  }

  private static func respond(to connection: NWConnection, status: String, body: String) {
    let head =
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data((head + body).utf8), contentContext: .finalMessage, isComplete: true,
      completion: .contentProcessed { _ in connection.cancel() })
  }

  private static let page = """
    <!doctype html><meta charset="utf-8"><title>DirBuff</title>\
    <body style="font: 16px -apple-system, sans-serif; text-align: center; margin-top: 20vh">\
    <p>You can close this tab and go back to DirBuff.</p>
    """
}
