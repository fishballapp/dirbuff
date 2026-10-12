import DirBuffKit
import Foundation
import Testing

/// Answers every request with the one response the test set, and keeps the last request.
private final class FakePolar: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var response: (status: Int, body: String) = (200, "{}")
  nonisolated(unsafe) static var lastBody: [String: Any] = [:]

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    Self.lastBody = Self.body(of: request)
    let response = HTTPURLResponse(
      url: request.url ?? URL(fileURLWithPath: "/"), statusCode: Self.response.status,
      httpVersion: nil, headerFields: nil)
    if let response {
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    client?.urlProtocol(self, didLoad: Data(Self.response.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  /// URLSession hands a protocol the body as a stream.
  private static func body(of request: URLRequest) -> [String: Any] {
    guard let stream = request.httpBodyStream else { return [:] }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
      data.append(buffer, count: count)
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }
}

private let polar = {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [FakePolar.self]
  return PolarLicensing(
    api: URL(fileURLWithPath: "/"), organizationID: "org",
    session: URLSession(configuration: configuration))
}()

private func answer(_ status: Int, _ body: String = "{}") {
  FakePolar.response = (status, body)
}

@Suite(.serialized) struct PolarLicensingTests {
  @Test func activatingSendsThisMacAndReturnsTheActivation() async throws {
    answer(200, #"{"id": "a1", "license_key": {"status": "granted"}}"#)
    #expect(try await polar.activate(key: "DIRBUFF-1", label: "Studio", machine: "m1") == "a1")
    #expect(FakePolar.lastBody["organization_id"] as? String == "org")
    #expect(FakePolar.lastBody["label"] as? String == "Studio")
    #expect(FakePolar.lastBody["conditions"] as? [String: String] == ["machine": "m1"])
  }

  @Test(arguments: [
    (
      403, #"{"detail": "License key activation limit already reached"}"#,
      PolarLicensing.Failure.activationLimitReached
    ),
    (403, #"{"detail": "License key is no longer active."}"#, .keyNotActive),
    (404, #"{"detail": "Not found"}"#, .keyNotFound),
    (429, "", .unreachable),
    (502, "", .unreachable),
  ])
  func activatingFailsAsPolarSays(status: Int, body: String, failure: PolarLicensing.Failure)
    async
  {
    answer(status, body)
    await #expect(throws: failure) {
      try await polar.activate(key: "DIRBUFF-1", label: "Studio", machine: "m1")
    }
  }

  @Test(arguments: [
    (200, #"{"status": "granted"}"#, PolarLicensing.Verdict.granted),
    (200, #"{"status": "revoked"}"#, .ended),
    (404, #"{"detail": "License key is no longer active."}"#, .ended),
    (404, #"{"detail": "License key does not match required conditions"}"#, .ended),
  ])
  func validatingReadsPolarsVerdict(status: Int, body: String, verdict: PolarLicensing.Verdict)
    async throws
  {
    answer(status, body)
    #expect(
      try await polar.validate(key: "DIRBUFF-1", activationID: "a1", machine: "m1") == verdict)
    #expect(FakePolar.lastBody["activation_id"] as? String == "a1")
    #expect(FakePolar.lastBody["conditions"] as? [String: String] == ["machine": "m1"])
  }

  @Test(arguments: [429, 500])
  func aRateLimitOrServerErrorIsNoVerdict(status: Int) async {
    answer(status)
    await #expect(throws: PolarLicensing.Failure.unreachable) {
      try await polar.validate(key: "DIRBUFF-1", activationID: "a1", machine: "m1")
    }
  }

  @Test(arguments: [204, 404])
  func deactivatingSucceedsWhenTheActivationIsGone(status: Int) async throws {
    answer(status)
    try await polar.deactivate(key: "DIRBUFF-1", activationID: "a1")
  }
}
