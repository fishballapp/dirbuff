import Testing

@testable import DirBuffUI

@Suite struct MainNavigationTests {
  @Test func opensAFoldersFilesOverItsPage() {
    #expect(MainNavigation(opening: .files(3)).path == [.folder(3), .files(3)])
    #expect(MainNavigation(opening: .run(7)) == MainNavigation(root: .history, path: [.run(7)]))
  }

  @Test func dropsARemovedFoldersPagesAndWhatsOverThem() {
    let nav = MainNavigation(path: [.folder(1), .files(1), .history(folderID: 1), .run(9)])
    #expect(nav.keeping(folders: [1]) == nav)
    #expect(nav.keeping(folders: [2]).path.isEmpty)
    let history = MainNavigation(root: .history, path: [.run(9)])
    #expect(history.keeping(folders: []) == history)
  }
}
