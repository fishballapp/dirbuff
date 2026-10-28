import Foundation

/// Where DirBuff's main window is: a root the sidebar chooses, and the pages pushed over it.
public struct MainNavigation: Hashable, Sendable {
  public var root: MainRoot
  public var path: [MainRoute]

  public init(root: MainRoot = .shelf, path: [MainRoute] = []) {
    self.root = root
    self.path = path
  }

  /// The shelf's root with `route` pushed on it, or History's when the route belongs to History. A
  /// folder's files sit over its page, so going back leads there.
  public init(opening route: MainRoute) {
    switch route {
    case .history(folderID: nil): self.init(root: .history)
    case .run: self.init(root: .history, path: [route])
    case .files(let id): self.init(root: .shelf, path: [.folder(id), route])
    case .folder, .history: self.init(root: .shelf, path: [route])
    }
  }

  /// The pages left once the folders in `ids` are all that exist: a removed folder's pages go, and
  /// everything pushed over them.
  public func keeping(folders ids: Set<Int64>) -> MainNavigation {
    let gone = path.firstIndex {
      switch $0 {
      case .folder(let id), .files(let id), .history(folderID: let id?): !ids.contains(id)
      case .history(folderID: nil), .run: false
      }
    }
    return MainNavigation(root: root, path: gone.map { Array(path[..<$0]) } ?? path)
  }
}

/// What the sidebar opens: the shelf of folders (with its filter) or History's list of runs.
public enum MainRoot: Hashable, Sendable {
  case shelf
  case history
}

/// A page pushed over the root.
public enum MainRoute: Hashable, Sendable {
  /// A folder's page: its buffs as cards.
  case folder(Int64)
  /// What goes next from a folder.
  case files(Int64)
  /// History's runs; with a folder, only the runs that touched it.
  case history(folderID: Int64?)
  /// One run's page, where what it removed can be put back.
  case run(Int64)
}
