import Foundation
import Security

/// Where Google's refresh token lives between launches.
public protocol RefreshTokenStore: Sendable {
  func load() throws -> String?
  func save(_ token: String) throws
  /// Removes the token; there being none is not a failure.
  func delete() throws
}

/// The refresh token as a generic password in the login Keychain: it is the user's credential, so
/// it is never in a file or in `UserDefaults`.
public struct KeychainRefreshTokenStore: RefreshTokenStore {
  public struct Failure: Error, Equatable {
    public var status: OSStatus
  }

  private let service: String
  private let account: String

  public init(
    service: String = "app.fishball.dirbuff.google-drive", account: String = "refresh-token"
  ) {
    self.service = service
    self.account = account
  }

  private var identity: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  public func load() throws -> String? {
    var found: CFTypeRef?
    let status = SecItemCopyMatching(
      identity.merging([
        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
      ]) { $1 } as CFDictionary, &found)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Failure(status: status) }
    return (found as? Data).flatMap { String(data: $0, encoding: .utf8) }
  }

  public func save(_ token: String) throws {
    let data = Data(token.utf8)
    let updated = SecItemUpdate(
      identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw Failure(status: updated) }
    let added = SecItemAdd(
      identity.merging([
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
      ]) { $1 } as CFDictionary, nil)
    guard added == errSecSuccess else { throw Failure(status: added) }
  }

  public func delete() throws {
    let status = SecItemDelete(identity as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure(status: status)
    }
  }
}
