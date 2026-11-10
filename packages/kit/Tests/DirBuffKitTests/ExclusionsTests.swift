import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// The walk that finds what restic can't see, and the patterns that tell restic what to leave out.
@Suite struct ExclusionsTests {
  @Test func aPatternMatchesOnlyTheNameOrPathItWasMadeFrom() {
    #expect(Exclusions.escaped("/data/a*b?[c]\\d") == "/data/a\\*b\\?\\[c\\]\\\\d")
    #expect(Exclusions.escaped("$HOME/x") == "$$HOME/x")
    #expect(Exclusions.escaped("#notes") == "\\#notes")
    #expect(Exclusions.escaped("plain name") == "plain name")
  }

  @Test func theWalkFindsWhatTimeMachineSkipsAndGoesNowhereLeftOut() throws {
    let scratch = try Scratch()
    let root = try canonicalPath(of: scratch.folder("folder"))
    for path in [
      "kept.txt", "skipped.db", "skipped-folder/inside.db", "node_modules/skipped.db",
      "left/out/skipped.db", "Library/skipped.db",
    ] {
      try scratch.file("folder/" + path)
    }
    for path in [
      "skipped.db", "skipped-folder", "skipped-folder/inside.db", "node_modules/skipped.db",
      "left/out/skipped.db", "Library/skipped.db",
    ] {
      try setTimeMachineExclusion(on: URL(fileURLWithPath: root + "/" + path))
    }

    let exclusions = Exclusions.scan(
      root, leftOut: [.path("left/out"), .name("extra")], home: root, own: ["/elsewhere"])

    #expect(exclusions.cloudOnlyCount == 0)
    #expect(
      exclusions.patterns
        == BackupDefaults.leftOutNames.appending("extra").sorted().map(Exclusions.escaped)
        + [
          root + "/Library", root + "/left/out", root + "/skipped-folder", root + "/skipped.db",
        ].map(Exclusions.escaped))
  }
}

extension Array {
  fileprivate func appending(_ element: Element) -> [Element] { self + [element] }
}
