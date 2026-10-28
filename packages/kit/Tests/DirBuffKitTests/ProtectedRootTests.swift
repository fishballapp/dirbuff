import Foundation
import Testing

@testable import DirBuffKit

@Suite struct ProtectedRootTests {
  @Test func protectsARootReachedThroughASymlink() throws {
    let scratch = try Scratch()
    let home = try scratch.folder("home")
    let library = try scratch.folder("elsewhere/Library")
    try FileManager.default.createSymbolicLink(
      at: home.appendingPathComponent("Library"), withDestinationURL: library)

    #expect(System.isProtected(library, home: home, volumes: []))
    #expect(!System.isProtected(try scratch.folder("elsewhere"), home: home, volumes: []))
  }

  @Test func leavesDesktopAndDocumentsToTheUser() throws {
    let scratch = try Scratch()
    let home = try scratch.folder("home")
    #expect(!System.isProtected(try scratch.folder("home/Desktop"), home: home, volumes: []))
    #expect(!System.isProtected(try scratch.folder("home/Documents"), home: home, volumes: []))
  }
}
