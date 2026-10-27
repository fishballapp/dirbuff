import DirBuffKit
import Foundation

/// A folder a clean-up moved things out of, and what it moved.
public struct CleanUpFolder: Sendable, Equatable {
  public var path: String
  public var entries: [JournalEntry]

  public init(path: String, entries: [JournalEntry]) {
    self.path = path
    self.entries = entries
  }
}

/// The notification after a clean-up that moved anything. It gives counts, never names, so it
/// reads the same with previews hidden, and reuses one request identifier (`id`) so the next
/// clean-up replaces it instead of stacking.
public struct CleanUpNotification: Sendable, Equatable {
  public static let id = "cleanUp"

  public enum Action: String, Sendable, Equatable {
    case putBack = "cleanUp.putBack"
    case show = "cleanUp.show"

    public var title: String {
      switch self {
      case .putBack: "Put Back"
      case .show: "Show"
      }
    }
  }

  public enum Category: String, Sendable, Equatable {
    case withPutBack = "cleanUp.putBack"
    case showOnly = "cleanUp.show"
  }

  private enum UserInfoKey {
    static let folderPath = "folderPath"
    static let putBackEntryIDs = "putBackEntryIDs"
  }

  /// "Downloads", "Downloads and Screenshots", or "Downloads, Screenshots and 1 more" when the
  /// clean-up moved things out of several folders, in the order the folders were added.
  public var title: String
  /// "5 items went to the Bin · 2.3 GB".
  public var body: String
  public var actions: [Action]
  /// The folder Show and tapping the notification open: the first folder the clean-up moved things
  /// out of, in the order the folders were added.
  public var folderPath: String
  /// The journal entries Put Back undoes: what went to the Bin and isn't back yet. Empty when
  /// nothing can be put back, as when everything was deleted permanently.
  public var putBackEntryIDs: [Int64]

  public var canPutBack: Bool { !putBackEntryIDs.isEmpty }

  public var category: Category {
    canPutBack ? .withPutBack : .showOnly
  }

  public var userInfo: [AnyHashable: Any] {
    [
      UserInfoKey.folderPath: folderPath,
      UserInfoKey.putBackEntryIDs: putBackEntryIDs,
    ]
  }

  /// Nil when the clean-up moved nothing, so there is nothing to say.
  ///
  /// - Parameter folders: Folders in the order they were added (the store's order).
  public init?(folders: [CleanUpFolder], binName: String = SystemBin.name) {
    let moved = folders.filter { !$0.entries.isEmpty }
    guard let first = moved.first else { return nil }
    let entries = moved.flatMap(\.entries)

    title = Self.title(for: moved.map { Self.name(of: $0.path) })

    let binned = entries.count { $0.disposal == .bin }
    let deleted = entries.count - binned
    let went = binned > 0 ? "\(items(binned)) went to the \(binName)" : nil
    let gone =
      deleted > 0 ? "\(items(deleted)) \(deleted == 1 ? "was" : "were") deleted permanently" : nil
    let what = [went, gone].compactMap { $0 }.joined(separator: ", ")
    body = "\(what) · \(bytes(entries.reduce(0) { $0 + $1.size }))"

    folderPath = first.path
    putBackEntryIDs =
      entries
      .filter { $0.disposal == .bin && $0.binnedPath != nil && $0.undoneAt == nil }
      .compactMap(\.id)
    actions = putBackEntryIDs.isEmpty ? [.show] : [.putBack, .show]
  }

  /// Nil when the clean-up moved nothing, so there is nothing to say.
  ///
  /// - Parameter reports: Folder reports in the order the folders were added (the store's order).
  public init?(
    runs: [Engine.RunResult],
    reports: [FolderReport],
    binName: String = SystemBin.name
  ) {
    let moved = Dictionary(grouping: runs.flatMap(\.journal), by: \.folderID)
    let folders = reports.compactMap { report -> CleanUpFolder? in
      guard let id = report.folder.id, let entries = moved[id] else { return nil }
      return CleanUpFolder(path: report.folder.path, entries: entries)
    }
    self.init(folders: folders, binName: binName)
  }

  /// Reads the folder path stored in a delivered notification's `userInfo`.
  public static func folderPath(from userInfo: [AnyHashable: Any]) -> String? {
    userInfo[UserInfoKey.folderPath] as? String
  }

  /// Reads the journal entry IDs stored in a delivered notification's `userInfo`.
  public static func putBackEntryIDs(from userInfo: [AnyHashable: Any]) -> [Int64] {
    if let ids = userInfo[UserInfoKey.putBackEntryIDs] as? [Int64] {
      return ids
    }
    if let numbers = userInfo[UserInfoKey.putBackEntryIDs] as? [NSNumber] {
      return numbers.map(\.int64Value)
    }
    return []
  }

  private static func title(for names: [String]) -> String {
    switch names.count {
    case 0: ""
    case 1: names[0]
    case 2: "\(names[0]) and \(names[1])"
    default: "\(names[0]), \(names[1]) and \(names.count - 2) more"
    }
  }

  private static func name(of path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
  }
}
