import Foundation

/// Where DirBuff's main window is: the sidebar row it shows, and the pages pushed over it.
public struct MainNavigation: Hashable, Sendable {
  public var place: SidebarPlace
  public var path: [MainPage]

  public init(_ place: SidebarPlace = .allFolders, path: [MainPage] = []) {
    self.place = place
    self.path = path
  }

  /// A page opened from outside the window (Finder's handoff, a notification), pushed over the
  /// sidebar row it belongs to: a folder's files and History over its page, a run over History.
  public init(opening page: MainPage) {
    switch page {
    case .files(let id), .folderHistory(let id): self.init(.folder(id), path: [page])
    case .run: self.init(.history, path: [page])
    }
  }

  /// The sidebar's selection, which is always the row shown, pages pushed over it or not. Choosing
  /// another row goes to it with nothing pushed. The list writes back the row it already shows (when
  /// it appears, say), which must not drop the pages over it, so that changes nothing.
  public var selection: SidebarPlace? {
    get { place }
    set {
      guard let newValue, newValue != place else { return }
      self = MainNavigation(newValue)
    }
  }

  /// Pushes `page` over what is shown.
  public mutating func open(_ page: MainPage) {
    path.append(page)
  }

  /// What is left once the folders in `ids` are all that exist: a removed folder's page goes back
  /// to All Folders, and a removed folder's pushed pages go, with everything pushed over them.
  public func keeping(folders ids: Set<Int64>) -> MainNavigation {
    if let id = place.folderID, !ids.contains(id) { return MainNavigation() }
    let gone = path.firstIndex { $0.folderID.map { !ids.contains($0) } ?? false }
    return MainNavigation(place, path: gone.map { Array(path[..<$0]) } ?? path)
  }
}

/// A row in the sidebar, and the page it shows.
public enum SidebarPlace: Hashable, Sendable {
  /// The shelf of every folder's tile.
  case allFolders
  /// Every buff, to drag onto a folder.
  case buffs
  /// Every run, newest first.
  case history
  /// A folder's page: its buffs as cards.
  case folder(Int64)

  var folderID: Int64? {
    if case .folder(let id) = self { return id }
    return nil
  }
}

/// A page pushed over a sidebar row, with a back button.
public enum MainPage: Hashable, Sendable {
  /// What is cleared next from a folder.
  case files(Int64)
  /// The runs that touched a folder.
  case folderHistory(Int64)
  /// One run's page, where what it removed can be put back.
  case run(Int64)

  var folderID: Int64? {
    switch self {
    case .files(let id), .folderHistory(let id): id
    case .run: nil
    }
  }
}
