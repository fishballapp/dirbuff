import Foundation
import Testing

@testable import DirBuffUI

/// What a buff may go on when something outside the window names it: a `dirbuff://` URL any app
/// or web page can open, or a drop into Finder. Only an existing folder the user can see.
@Suite struct BuffTargetTests {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("BuffTargetTests-\(UUID().uuidString)")

  init() throws {
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Tool.app/Contents"), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appendingPathComponent("note.txt"))
  }

  @Test func anExistingFolderTakesABuff() {
    #expect(isFolderForABuff(root.appendingPathComponent("Documents")))
  }

  @Test func aFileAPackageOrNothingDoesnt() {
    #expect(!isFolderForABuff(root.appendingPathComponent("note.txt")))
    #expect(!isFolderForABuff(root.appendingPathComponent("Tool.app")))
    #expect(!isFolderForABuff(root.appendingPathComponent("Missing")))
  }

  @Test func aHiddenOrSystemFolderDoesnt() {
    #expect(!isFolderForABuff(URL(fileURLWithPath: "/System/Library")))
    #expect(
      !isFolderForABuff(
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          "Library/Caches")))
  }

  @Test func addingBackupFromOutsideAsksFirst() {
    let alert = BackupAlert.addBackup(folderName: "Documents")
    #expect(alert.title == "Back up Documents to Google Drive?")
    #expect(alert.buttons == ["Back Up", "Cancel"])
  }
}
