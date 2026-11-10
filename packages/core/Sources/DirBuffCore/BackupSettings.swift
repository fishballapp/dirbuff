/// How long a Backup folder's history goes back. Each keeps the latest snapshots, then fewer the
/// older they get.
public enum BackupHistory: String, Sendable, Codable, CaseIterable {
  /// Every version, thinning with age, and one a year for ever.
  case forever
  case oneYear
  case thirtyDays
}

/// A Backup folder's one setting.
public struct BackupSettings: Sendable, Equatable {
  public var history: BackupHistory

  public init(history: BackupHistory = .forever) {
    self.history = history
  }
}

/// Something a Backup folder leaves out, besides what every Backup folder does (`BackupDefaults`).
public enum LeaveOut: Hashable, Sendable {
  /// One file or folder, by its path inside the backed-up folder ("Projects/old.zip").
  case path(String)
  /// Every file or folder of this name, anywhere inside it.
  case name(String)
}

/// What every Backup folder leaves out, so the card can list it in words: nothing is left out
/// silently.
public enum BackupDefaults {
  /// What a build or a tool makes again, left out by name anywhere in the folder.
  public static let leftOutNames = [
    "node_modules", ".venv", ".next", ".turbo", ".terraform", "__pycache__", ".DS_Store",
  ]
  /// The extended attribute macOS's apps set on what Time Machine must skip (a cache, a database
  /// that can be rebuilt); `tmutil addexclusion` sets it too.
  public static let timeMachineExclusionAttribute =
    "com.apple.metadata:com_apple_backup_excludeItem"
  /// A folder holding a file of this name that begins with `cacheDirectorySignature` is a cache.
  public static let cacheDirectoryTag = "CACHEDIR.TAG"
  public static let cacheDirectorySignature = "Signature: 8a477f597d28d172789f06886806bc55"
}
