import Foundation

/// Where the Mac's repository is, and its `password.txt`: the key, kept beside the backup unless
/// Private Backup is on. restic reaches it only through `withAddress`.
public protocol BackupRepository: Sendable {
  /// Runs one restic command against the address `-r` takes, valid until `body` returns. A bridge
  /// to a remote store starts for each command and stops after it, so none outlives a run.
  func withAddress<Result: Sendable>(_ body: @Sendable (String) async throws -> Result)
    async throws -> Result
  func hasPasswordFile() async throws -> Bool
  /// Nil when there's none.
  func readPasswordFile() async throws -> String?
  func writePasswordFile(_ password: String) async throws
  /// Deletes it for good, not to a bin from which it could be read again.
  func removePasswordFile() async throws
}

/// A repository in a folder on this Mac, laid out as restic lays out any local repository.
public struct LocalRepository: BackupRepository {
  public let folder: URL

  public init(folder: URL) {
    self.folder = folder
  }

  private var passwordFile: URL { folder.appendingPathComponent("password.txt") }

  public func withAddress<Result: Sendable>(_ body: @Sendable (String) async throws -> Result)
    async throws -> Result
  {
    try await body(folder.path)
  }

  public func hasPasswordFile() async throws -> Bool {
    FileManager.default.fileExists(atPath: passwordFile.path)
  }

  public func readPasswordFile() async throws -> String? {
    guard try await hasPasswordFile() else { return nil }
    return try String(contentsOf: passwordFile, encoding: .utf8)
  }

  public func writePasswordFile(_ password: String) async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(password.utf8).write(to: passwordFile, options: .atomic)
  }

  public func removePasswordFile() async throws {
    guard try await hasPasswordFile() else { return }
    try FileManager.default.removeItem(at: passwordFile)
  }
}
