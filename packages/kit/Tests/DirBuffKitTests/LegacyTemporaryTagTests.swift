import Foundation
import Testing

@testable import DirBuffKit

@Suite struct LegacyTemporaryTagTests {
  @Test func removesOnlyItsOwnTag() throws {
    let scratch = try Scratch()
    try setFinderTags(["Red", LegacyTemporaryTag.name], on: scratch.url)
    #expect(try LegacyTemporaryTag.isSet(on: scratch.url))

    try LegacyTemporaryTag.remove(from: scratch.url)

    #expect(try !LegacyTemporaryTag.isSet(on: scratch.url))
    #expect(try finderTags(of: scratch.url) == ["Red"])
  }

  @Test func aFolderThatCantBeReadIsNotTaggedButAnError() throws {
    let scratch = try Scratch()
    let gone = try scratch.folder("Gone")
    try FileManager.default.removeItem(at: gone)

    #expect(throws: (any Error).self) { try LegacyTemporaryTag.isSet(on: gone) }
  }
}
