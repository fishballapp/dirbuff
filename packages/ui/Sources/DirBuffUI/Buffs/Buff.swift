import DirBuffCore

/// What every surface says about a buff.
extension Buff {
  public var name: String {
    switch self {
    case .temporary: "Temporary"
    case .backup: "Backup"
    case .organise: "Organise"
    case .search: "Search"
    }
  }

  /// What it does, on the Buffs page.
  public var summary: String {
    switch self {
    case .temporary:
      "Clears files when they’re old, the folder is too big, disk space is low or the Mac restarts. Each clean-up appears in History."
    case .backup:
      "Backs up files to your Google Drive, with version history to restore them."
    case .organise: "Sorts files into subfolders by kind and date."
    case .search: "Find a file by what’s in it, not only its name."
    }
  }

  /// Whether this build can put it on a folder. The rest are listed, greyed, as Soon.
  public var isAvailable: Bool {
    switch self {
    case .temporary, .backup: true
    case .organise, .search: false
    }
  }

  /// Whether a protected folder (`MainState.isProtected`) refuses it. Only Temporary clears
  /// things; Backup goes on Home too, which leaves out its Library instead.
  public var refusesProtectedFolders: Bool { self == .temporary }
}
