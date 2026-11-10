import Foundation

/// One line restic printed under `--json`, as a typed value.
///
/// `status`, `summary` and `error` mean different things to different commands, so a line is read
/// for the command that printed it.
public enum ResticMessage: Equatable, Sendable {
  case backupProgress(BackupProgress)
  case backupSummary(BackupSummary)
  case restoreProgress(RestoreProgress)
  case restoreSummary(RestoreSummary)
  /// A file restic couldn't read or write while the command went on.
  case itemError(ItemError)
  case checkSummary(CheckSummary)
  case checkError(message: String)
  case initialized(repositoryID: String)
  /// The command's last word when it failed (printed on stderr).
  case exitError(code: Int32, message: String)
  /// Anything else: the JSON document that `snapshots` and `forget` print, `prune`'s plain
  /// text, and message types this runner doesn't know.
  case other(String)

  /// The commands whose lines have messages of their own.
  public enum Source: Sendable {
    case backup, restore, check, initialisation, other
  }

  public init(line: String, from source: Source) {
    guard line.hasPrefix("{"),
      let envelope = try? Self.decoder.decode(Envelope.self, from: Data(line.utf8))
    else {
      self = .other(line)
      return
    }
    self = Self.decode(line, type: envelope.messageType, from: source) ?? .other(line)
  }

  private struct Envelope: Decodable {
    var messageType: String
  }

  private static func decode(_ line: String, type: String, from source: Source) -> Self? {
    let data = Data(line.utf8)
    func read<Value: Decodable>(_ type: Value.Type) -> Value? {
      try? decoder.decode(type, from: data)
    }
    switch (type, source) {
    case ("exit_error", _):
      return read(ExitErrorLine.self).map { .exitError(code: $0.code, message: $0.message) }
    case ("error", .backup), ("error", .restore):
      return read(ItemErrorLine.self).map { .itemError($0.itemError) }
    case ("status", .backup): return read(BackupProgress.self).map { .backupProgress($0) }
    case ("summary", .backup): return read(BackupSummary.self).map { .backupSummary($0) }
    case ("status", .restore): return read(RestoreProgress.self).map { .restoreProgress($0) }
    case ("summary", .restore): return read(RestoreSummary.self).map { .restoreSummary($0) }
    case ("summary", .check): return read(CheckSummary.self).map { .checkSummary($0) }
    case ("error", .check):
      return read(CheckErrorLine.self).map { .checkError(message: $0.message) }
    case ("initialized", .initialisation):
      return read(InitializedLine.self).map { .initialized(repositoryID: $0.id) }
    default: return nil
    }
  }

  /// Reads the JSON document a command printed whole (`snapshots`, `forget`).
  static func decodeDocument<Value: Decodable>(_ type: Value.Type, from text: String) throws
    -> Value
  {
    try decoder.decode(type, from: Data(text.utf8))
  }

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let text = try decoder.singleValueContainer().decode(String.self)
      guard
        let date =
          (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
          ?? (try? Date(text, strategy: .iso8601))
      else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "Not a restic date: \(text)"))
      }
      return date
    }
    return decoder
  }()
}

// MARK: - What commands report

/// `backup`'s running count. restic prints one every second whether or not anything moved, and
/// leaves out what is zero.
public struct BackupProgress: Equatable, Sendable, Decodable {
  public var percentDone: Double
  @ZeroIfOmitted public var secondsElapsed: UInt64
  @ZeroIfOmitted public var totalFiles: UInt64
  @ZeroIfOmitted public var filesDone: UInt64
  @ZeroIfOmitted public var totalBytes: UInt64
  @ZeroIfOmitted public var bytesDone: UInt64
  @ZeroIfOmitted public var errorCount: UInt64
  @EmptyIfOmitted public var currentFiles: [String]
}

/// What a finished `backup` added to the repository.
public struct BackupSummary: Equatable, Sendable, Decodable {
  public var filesNew: UInt64
  public var filesChanged: UInt64
  public var filesUnmodified: UInt64
  public var dirsNew: UInt64
  public var dirsChanged: UInt64
  public var dirsUnmodified: UInt64
  public var dataAdded: UInt64
  public var dataAddedPacked: UInt64
  public var totalFilesProcessed: UInt64
  public var totalBytesProcessed: UInt64
  public var totalDuration: Double
  /// Absent when nothing was saved, as in a dry run.
  public var snapshotId: String?
}

public struct RestoreProgress: Equatable, Sendable, Decodable {
  public var percentDone: Double
  @ZeroIfOmitted public var secondsElapsed: UInt64
  @ZeroIfOmitted public var totalFiles: UInt64
  @ZeroIfOmitted public var filesRestored: UInt64
  @ZeroIfOmitted public var filesSkipped: UInt64
  @ZeroIfOmitted public var filesDeleted: UInt64
  @ZeroIfOmitted public var totalBytes: UInt64
  @ZeroIfOmitted public var bytesRestored: UInt64
  @ZeroIfOmitted public var bytesSkipped: UInt64
}

public struct RestoreSummary: Equatable, Sendable, Decodable {
  @ZeroIfOmitted public var totalFiles: UInt64
  @ZeroIfOmitted public var filesRestored: UInt64
  @ZeroIfOmitted public var filesSkipped: UInt64
  @ZeroIfOmitted public var filesDeleted: UInt64
  @ZeroIfOmitted public var totalBytes: UInt64
  @ZeroIfOmitted public var bytesRestored: UInt64
  @ZeroIfOmitted public var bytesSkipped: UInt64
}

/// A file restic couldn't read (`backup`) or write (`restore`).
public struct ItemError: Equatable, Sendable {
  public var item: String
  public var message: String
  /// What restic was doing: `scan` or `archival` for a backup.
  public var during: String
}

/// What `check` found. An unhealthy repository has errors or broken packs.
public struct CheckSummary: Equatable, Sendable, Decodable {
  public var numErrors: Int
  @EmptyIfOmitted public var brokenPacks: [String]
  public var suggestRepairIndex: Bool
  public var suggestPrune: Bool

  public var isHealthy: Bool { numErrors == 0 && brokenPacks.isEmpty }
}

// MARK: - Wire shapes that become one of the values above

private struct ExitErrorLine: Decodable {
  var code: Int32
  var message: String
}

private struct ItemErrorLine: Decodable {
  struct Body: Decodable { var message: String }
  var error: Body
  var during: String
  var item: String

  var itemError: ItemError { ItemError(item: item, message: error.message, during: during) }
}

private struct CheckErrorLine: Decodable {
  var message: String
}

private struct InitializedLine: Decodable {
  var id: String
}

// MARK: - Progress

extension ResticMessage {
  /// How far the command has got, without the clock: two progress messages with the same mark
  /// mean nothing moved between them. Nil for a message that isn't progress.
  var progressMark: ProgressMark? {
    switch self {
    case .backupProgress(let progress):
      return ProgressMark(
        numbers: [
          progress.totalFiles, progress.filesDone, progress.totalBytes, progress.bytesDone,
          progress.errorCount,
        ], names: progress.currentFiles)
    case .restoreProgress(let progress):
      return ProgressMark(
        numbers: [
          progress.totalFiles, progress.filesRestored, progress.filesSkipped,
          progress.filesDeleted, progress.totalBytes, progress.bytesRestored,
          progress.bytesSkipped,
        ], names: [])
    default:
      return nil
    }
  }

  struct ProgressMark: Hashable {
    var numbers: [UInt64]
    var names: [String]
  }
}

// MARK: - Fields restic leaves out when they are zero

@propertyWrapper
public struct ZeroIfOmitted<Value: Decodable & Equatable & Sendable & ExpressibleByIntegerLiteral>:
  Decodable, Equatable, Sendable
{
  public var wrappedValue: Value

  public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }

  public init(from decoder: any Decoder) throws {
    wrappedValue = try Value(from: decoder)
  }
}

@propertyWrapper
public struct EmptyIfOmitted<Element: Decodable & Equatable & Sendable>:
  Decodable, Equatable, Sendable
{
  public var wrappedValue: [Element]

  public init(wrappedValue: [Element]) { self.wrappedValue = wrappedValue }

  public init(from decoder: any Decoder) throws {
    wrappedValue = try [Element](from: decoder)
  }
}

extension KeyedDecodingContainer {
  func decode<Value>(_ type: ZeroIfOmitted<Value>.Type, forKey key: Key) throws
    -> ZeroIfOmitted<Value>
  {
    try decodeIfPresent(type, forKey: key) ?? ZeroIfOmitted(wrappedValue: 0)
  }

  func decode<Element>(_ type: EmptyIfOmitted<Element>.Type, forKey key: Key) throws
    -> EmptyIfOmitted<Element>
  {
    try decodeIfPresent(type, forKey: key) ?? EmptyIfOmitted(wrappedValue: [])
  }
}
