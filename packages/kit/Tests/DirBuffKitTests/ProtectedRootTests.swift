import Foundation
import Testing

@testable import DirBuffKit

@Suite struct ProtectedRootTests {
  @Test func protectsARootReachedThroughASymlink() throws {
    let scratch = try Scratch()
    let home = try scratch.folder("home")
    let documents = try scratch.folder("elsewhere/Documents")
    try FileManager.default.createSymbolicLink(
      at: home.appendingPathComponent("Documents"), withDestinationURL: documents)

    #expect(System.isProtected(documents, home: home, volumes: []))
    #expect(!System.isProtected(try scratch.folder("elsewhere"), home: home, volumes: []))
  }
}
