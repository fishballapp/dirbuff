import Foundation

/// Polar's licence-key endpoints for customers. They take no secret, so the app calls them
/// directly. What each answer means was checked against Polar's sandbox.
public struct PolarLicensing: Sendable {
  public enum Failure: Error, Equatable {
    case activationLimitReached
    /// Cancelled, refunded, or disabled.
    case keyNotActive
    case keyNotFound
    /// No answer about the licence: offline, rate limited, or Polar failing. Try again later.
    case unreachable
  }

  public enum Verdict: Sendable, Equatable {
    case granted
    case ended
  }

  private let api: URL
  private let organizationID: String
  private let session: URLSession

  public init(api: URL, organizationID: String, session: URLSession = .shared) {
    self.api = api
    self.organizationID = organizationID
    self.session = session
  }

  /// Activates the key on this Mac and returns the activation's ID.
  public func activate(key: String, label: String, machine: String) async throws -> String {
    let (data, status) = try await post("activate", key: key, label: label, machine: machine)
    switch status {
    case 200:
      return try JSONDecoder().decode(Activation.self, from: data).id
    case 403:
      // Polar answers 403 to both; only the detail tells them apart.
      let detail = try? JSONDecoder().decode(Problem.self, from: data).detail
      throw detail?.contains("activation limit") == true
        ? Failure.activationLimitReached : Failure.keyNotActive
    case 404:
      throw Failure.keyNotFound
    default:
      throw Failure.unreachable
    }
  }

  public func validate(key: String, activationID: String, machine: String) async throws -> Verdict {
    let (data, status) = try await post(
      "validate", key: key, activationID: activationID, machine: machine)
    switch status {
    case 200:
      return try JSONDecoder().decode(Key.self, from: data).status == "granted" ? .granted : .ended
    case 404:
      // The key is unknown or no longer active, the activation was removed in the customer
      // portal, or it belongs to another Mac.
      return .ended
    default:
      throw Failure.unreachable
    }
  }

  public func deactivate(key: String, activationID: String) async throws {
    let (_, status) = try await post("deactivate", key: key, activationID: activationID)
    // 404: the activation is already gone, which is what deactivating wanted.
    guard status == 204 || status == 404 else { throw Failure.unreachable }
  }

  private struct Body: Encodable {
    var key: String
    var organizationID: String
    var activationID: String?
    var label: String?
    var conditions: [String: String]?
  }

  private struct Activation: Decodable { var id: String }
  private struct Key: Decodable { var status: String }
  private struct Problem: Decodable { var detail: String }

  private func post(
    _ endpoint: String, key: String, activationID: String? = nil, label: String? = nil,
    machine: String? = nil
  ) async throws -> (Data, Int) {
    let body = Body(
      key: key, organizationID: organizationID, activationID: activationID, label: label,
      conditions: machine.map { ["machine": $0] })
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    var request = URLRequest(
      url: api.appending(path: "v1/customer-portal/license-keys/\(endpoint)"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try encoder.encode(body)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw Failure.unreachable
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    // Rate limits and server errors say nothing about the licence.
    guard status != 429, status < 500 else { throw Failure.unreachable }
    return (data, status)
  }
}
