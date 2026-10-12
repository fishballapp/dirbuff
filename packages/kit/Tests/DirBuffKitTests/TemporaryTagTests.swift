import Foundation
import Testing

@testable import DirBuffKit

@Suite struct TemporaryTagTests {
  @Test func setsAndRemovesOnlyItsOwnTag() throws {
    let scratch = try Scratch()
    try (scratch.url as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)

    try TemporaryTag.set(on: scratch.url)
    #expect(TemporaryTag.isSet(on: scratch.url))
    try TemporaryTag.remove(from: scratch.url)
    #expect(!TemporaryTag.isSet(on: scratch.url))

    let tags = try URL(fileURLWithPath: scratch.url.path).resourceValues(forKeys: [.tagNamesKey])
    #expect(tags.tagNames == ["Red"])
  }
}
