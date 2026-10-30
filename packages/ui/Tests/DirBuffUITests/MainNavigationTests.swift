import Testing

@testable import DirBuffUI

@Suite struct MainNavigationTests {
  @Test func startsAtAllFolders() {
    #expect(MainNavigation() == MainNavigation(.allFolders, path: []))
  }

  @Test func theSidebarGoesToItsRowWithNothingPushed() {
    var navigation = MainNavigation(opening: .files(3))
    navigation.selection = .buffs
    #expect(navigation == MainNavigation(.buffs))
    navigation.selection = .folder(4)
    #expect(navigation == MainNavigation(.folder(4)))
  }

  @Test func theSidebarShowsTheRowAPageIsPushedOver() {
    #expect(MainNavigation(opening: .files(3)).selection == .folder(3))
    #expect(MainNavigation(opening: .run(7)).selection == .history)
  }

  @Test func theListWritingBackItsRowKeepsThePages() {
    var navigation = MainNavigation(opening: .run(7))
    navigation.selection = .history
    navigation.selection = nil
    #expect(navigation == MainNavigation(.history, path: [.run(7)]))
  }

  @Test func aTileOrAFolderPillSelectsTheFoldersRow() {
    let navigation = MainNavigation(.folder(2))
    #expect(navigation.selection == .folder(2))
    #expect(navigation.path.isEmpty)
  }

  @Test func findersHandoffOpensAFolderOrItsFiles() {
    #expect(MainNavigation(.folder(3)).path.isEmpty)
    #expect(MainNavigation(opening: .files(3)) == MainNavigation(.folder(3), path: [.files(3)]))
  }

  @Test func aNotificationOpensItsRunOverHistory() {
    #expect(MainNavigation(opening: .run(7)) == MainNavigation(.history, path: [.run(7)]))
  }

  @Test func filesAndRunsPushOverWhatIsShown() {
    var folder = MainNavigation(.folder(3))
    folder.open(.files(3))
    #expect(folder == MainNavigation(.folder(3), path: [.files(3)]))
    folder.open(.folderHistory(3))
    folder.open(.run(9))
    #expect(folder.path == [.files(3), .folderHistory(3), .run(9)])

    var history = MainNavigation(.history)
    history.open(.run(7))
    #expect(history == MainNavigation(.history, path: [.run(7)]))
  }

  @Test func aRemovedFolderGoesBackToAllFolders() {
    let navigation = MainNavigation(.folder(1), path: [.files(1)])
    #expect(navigation.keeping(folders: [1]) == navigation)
    #expect(navigation.keeping(folders: [2]) == MainNavigation())
  }

  @Test func aRemovedFoldersPagesGoWithWhatIsOverThem() {
    let navigation = MainNavigation(.history, path: [.run(9), .folderHistory(1), .run(4)])
    #expect(navigation.keeping(folders: [2]) == MainNavigation(.history, path: [.run(9)]))
    let history = MainNavigation(.history, path: [.run(9)])
    #expect(history.keeping(folders: []) == history)
  }
}
