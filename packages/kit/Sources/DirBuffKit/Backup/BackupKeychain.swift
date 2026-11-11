import Foundation
import Security

/// Where this Mac keeps the password that opens its repository, when the user set one, so a run
/// never asks for it. None kept: the repository opens with no password.
public protocol BackupKeychain: Sendable {
  func key(_ slot: BackupKeychainSlot) throws -> String?
  func save(_ key: String, in slot: BackupKeychainSlot) throws
  /// There being none is not a failure.
  func delete(_ slot: BackupKeychainSlot) throws
}

/// The password in use, or the one a change of repository holds until the database has made
/// the change: the Keychain and the database can't change in one step.
public enum BackupKeychainSlot: Sendable {
  case current, staged
}

extension BackupKeychain {
  public func key() throws -> String? { try key(.current) }
  public func save(_ key: String) throws { try save(key, in: .current) }
  public func delete() throws { try delete(.current) }
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

  public func key(_ slot: BackupKeychainSlot) throws -> String? {
    var query = itemQuery(slot)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
    return String(decoding: data, as: UTF8.self)
  }

  public func save(_ key: String, in slot: BackupKeychainSlot) throws {
    let data = Data(key.utf8)
    let updated = SecItemUpdate(
      itemQuery(slot) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw Failure(status: updated) }
    var item = itemQuery(slot)
    item[kSecValueData as String] = data
    item[kSecAttrLabel as String] = "DirBuff Backup"
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else { throw Failure(status: added) }
  }

  public func delete(_ slot: BackupKeychainSlot) throws {
    let status = SecItemDelete(itemQuery(slot) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure(status: status)
    }
  }

  private func itemQuery(_ slot: BackupKeychainSlot) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: slot == .staged ? account + ".staged" : account,
    ]
  }
}
