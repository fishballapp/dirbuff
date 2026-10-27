import DirBuffCore
import Foundation

/// A buff a folder wears, in the words Finder's right-click menu shows: its setting and what it
/// does next.
public struct FinderBuff: Sendable, Equatable, Codable {
  public var buff: Buff
  /// The same setting sentence the app's tiles show, e.g. "Older than 14 days, to the Bin".
  public var setting: String
  /// "12 items go tomorrow · 1.3 GB", the buff's next event or status.
  public var nextEvent: String

  public init(buff: Buff, setting: String, nextEvent: String) {
    self.buff = buff
    self.setting = setting
    self.nextEvent = nextEvent
  }

  /// Nil for a buff that is only taken off, which isn't worn in Finder.
  public init?(_ row: BuffRow) {
    guard row.state.mark != nil else { return nil }
    self.init(buff: row.buff, setting: row.setting, nextEvent: row.status)
  }
}

/// One folder's state for the Finder extension: its resolved path, its badge mark, and the buffs
/// it wears.
public struct FinderFolder: Sendable, Equatable, Codable {
  public var path: String
  /// The mark Finder shows: nil for a plain folder, and nil whenever the licence doesn't allow
  /// cleaning (trial ended, licence ended, or licence unconfirmed).
  public var mark: MarkState?
  /// The buffs worn, in `Buff` order. A buff just taken off isn't worn.
  public var buffs: [FinderBuff]

  public init(path: String, mark: MarkState?, buffs: [FinderBuff]) {
    self.path = path
    self.mark = mark
    self.buffs = buffs
  }

  /// Finder shows the mark only while the licence allows cleaning: when the trial or licence has
  /// ended or the licence is unconfirmed, every mark leaves Finder while the folder's buffs stay in
  /// the menu.
  public init?(_ folder: FolderState, licence: Licence) {
    let buffs = folder.buffs.compactMap(FinderBuff.init)
    guard !buffs.isEmpty else { return nil }
    self.init(
      path: resolvedFinderPath(folder.path),
      mark: licence.mayClean ? folder.mark : nil,
      buffs: buffs
    )
  }
}

/// Everything the app publishes to the Finder extension through the shared app group.
public struct FinderSnapshot: Sendable, Equatable, Codable {
  public var folders: [FinderFolder]
  public var protectedFolderPaths: [String]
  public var binName: String

  public init(
    folders: [FinderFolder] = [],
    protectedFolderPaths: [String] = [],
    binName: String = SystemBin.name
  ) {
    self.folders = folders
    self.protectedFolderPaths = protectedFolderPaths
    self.binName = binName
  }

  /// Builds the snapshot for `folders` under `licence`. Whenever the licence doesn't allow cleaning
  /// (trial ended, licence ended, or licence unconfirmed), no folder shows a mark in Finder, and a
  /// buff just taken off (`.takenOff`) is already off in Finder.
  public init(
    folders: [FolderState],
    licence: Licence,
    protectedFolderPaths: [String],
    binName: String = SystemBin.name
  ) {
    self.folders = folders.compactMap { FinderFolder($0, licence: licence) }
    self.protectedFolderPaths = protectedFolderPaths.map(resolvedFinderPath)
    self.binName = binName
  }

  /// Encodes the snapshot with sorted keys so equal snapshots always produce identical bytes.
  public func encoded() -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(self)
  }

  /// Decodes a published snapshot, or returns an empty snapshot when none has been written yet.
  public static func decode(_ data: Data?) -> FinderSnapshot {
    guard let data, let decoded = try? JSONDecoder().decode(FinderSnapshot.self, from: data) else {
      return FinderSnapshot()
    }
    return decoded
  }

  /// The badge mark for `folder`, or nil for a plain folder or when the licence doesn't allow
  /// cleaning.
  public func badge(for folder: URL) -> MarkState? {
    let path = resolvedFinderPath(folder.path)
    return folders.first { $0.path == path }?.mark
  }

  /// The folders whose badge changed between `old` and `self`, paired with their new badge (or nil
  /// when the badge comes off).
  public func badgeChanges(from old: FinderSnapshot) -> [(path: String, mark: MarkState?)] {
    let oldMarks = Dictionary(
      old.folders.compactMap { folder in folder.mark.map { (folder.path, $0) } },
      uniquingKeysWith: { _, latest in latest }
    )
    let newMarks = Dictionary(
      folders.compactMap { folder in folder.mark.map { (folder.path, $0) } },
      uniquingKeysWith: { _, latest in latest }
    )
    let paths = Set(oldMarks.keys).union(newMarks.keys).sorted()
    return paths.compactMap { path in
      let before = oldMarks[path]
      let after = newMarks[path]
      guard before != after else { return nil }
      return (path: path, mark: after)
    }
  }

  /// Finder's right-click submenu for `folder`.
  public func menu(for folder: URL) -> FinderMenu {
    let path = resolvedFinderPath(folder.path)
    let name = folder.lastPathComponent
    if let match = folders.first(where: { $0.path == path }), !match.buffs.isEmpty {
      return .buffs(folderName: name, worn: match.buffs, binName: binName)
    }
    let isProtected = protectedFolderPaths.contains(path)
    return .addBuff(folderName: name, isProtected: isProtected, binName: binName)
  }
}

extension MarkState: Codable {}

extension Buff: Codable {
  public init(from decoder: any Decoder) throws {
    let key = try decoder.singleValueContainer().decode(String.self)
    switch key {
    case "temporary": self = .temporary
    case "backup": self = .backup
    case "organise": self = .organise
    case "search": self = .search
    default:
      throw DecodingError.dataCorrupted(
        DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown buff")
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    let key =
      switch self {
      case .temporary: "temporary"
      case .backup: "backup"
      case .organise: "organise"
      case .search: "search"
      }
    try container.encode(key)
  }
}

/// Normalizes `/var/…` and `/private/var/…` to the same resolved path so the app's canonical paths
/// match the URLs Finder hands to the extension.
public func resolvedFinderPath(_ path: String) -> String {
  URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}
