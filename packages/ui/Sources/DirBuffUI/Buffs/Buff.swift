/// A capability a folder wears. A folder wears at most one of each, always listed in this order.
public enum Buff: CaseIterable, Sendable, Hashable {
  case temporary
  case backup
  case organise
  case search

  public var name: String {
    switch self {
    case .temporary: "Temporary"
    case .backup: "Backup"
    case .organise: "Organise"
    case .search: "Search"
    }
  }

  /// One line of what it does, in + Buff.
  public var summary: String {
    switch self {
    case .temporary: "Clears old files automatically"
    case .backup: "Every version, to Google Drive"
    case .organise: "Files into subfolders"
    case .search: "Find files by what’s in them"
    }
  }

  /// Whether this build can put it on a folder. The rest are listed, greyed, as Soon.
  public var isAvailable: Bool { self == .temporary }
}
