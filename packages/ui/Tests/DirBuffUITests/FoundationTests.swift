import AppKit
import SwiftUI
import Testing

@testable import DirBuffUI

@Suite struct FoundationTests {
  @Test func theMostUrgentMarkStateWins() {
    #expect([MarkState.atRest, .needsYou, .paused].max() == .needsYou)
    #expect([MarkState.atRest, .paused, .working].max() == .working)
    #expect([MarkState.atRest, .paused].max() == .paused)
  }

  @Test func onlyTemporaryCanBePutOnInThisBuild() {
    #expect(Buff.allCases.filter(\.isAvailable) == [.temporary])
  }

  @MainActor
  @Test func theCapsFaceIsBundledAndRegistered() {
    _ = Caps.font(size: 13)
    #expect(NSFont(name: "BarlowCondensed-SemiBold", size: 13) != nil)
    #expect(NSFont(name: "BarlowCondensed-Medium", size: 13) != nil)
    #expect(NSFont(name: "BarlowCondensed-Bold", size: 13) != nil)
  }
}
