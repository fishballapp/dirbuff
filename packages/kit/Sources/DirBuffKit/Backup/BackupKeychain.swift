import Foundation
import Security

/// Where this Mac keeps the key that opens its repository, so a run never asks for it.
public protocol BackupKeychain: Sendable {
  func key() throws -> String?
  func save(_ key: String) throws
}

/// The user's login Keychain, as one generic password: the user's own credential, as safe as
/// their other saved passwords.
public struct LoginKeychain: BackupKeychain {
  public let service: String
  public let account: String

  public init(service: String = "app.fishball.dirbuff.backup", account: String = "repository") {
    self.service = service
    self.account = account
  }

  public struct Failure: Error, Equatable {
    public var status: OSStatus
  }

  public func key() throws -> String? {
    var query = itemQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
    return String(decoding: data, as: UTF8.self)
  }

  public func save(_ key: String) throws {
    let data = Data(key.utf8)
    let updated = SecItemUpdate(
      itemQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw Failure(status: updated) }
    var item = itemQuery
    item[kSecValueData as String] = data
    item[kSecAttrLabel as String] = "DirBuff Backup"
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else { throw Failure(status: added) }
  }

  private var itemQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
