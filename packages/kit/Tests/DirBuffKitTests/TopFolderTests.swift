import Foundation
import Testing

@testable import DirBuffKit

@Suite struct TopFolderTests {
  @Test func listsOnlyTheFoldersAtTheTopOfEachVolume() throws {
    let scratch = try Scratch()
    let terry = try scratch.folder("terry")
    let stuff = try scratch.folder("terry/stuff")
    try scratch.folder("terry/stuff/inner")
    try scratch.folder("terry/.Trashes")
    try scratch.folder("terry/Tool.app")
    try scratch.file("terry/notes.txt")
    let backup = try scratch.folder("backup")
    let photos = try scratch.folder("backup/Photos")

    #expect(
      System.topFolderPaths(of: [terry, backup])
        == [photos, stuff].map { $0.resolvingSymlinksInPath().path }.sorted())
  }

  @Test func aVolumeThatCantBeListedHasNoFolders() throws {
    let scratch = try Scratch()
    let gone = scratch.url.appendingPathComponent("unplugged")

    #expect(System.topFolderPaths(of: [gone]).isEmpty)
  }
}
