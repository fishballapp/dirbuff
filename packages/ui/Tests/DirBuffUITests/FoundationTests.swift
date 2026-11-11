import AppKit
import DirBuffCore
import SwiftUI
import Testing

@testable import DirBuffUI

@Suite struct FoundationTests {
  @Test func theMostUrgentMarkStateWins() {
    #expect([MarkState.atRest, .needsYou, .working].max() == .needsYou)
    #expect([MarkState.atRest, .working].max() == .working)
    #expect(MarkState.allCases == [.atRest, .working, .needsYou])
  }

  @Test func temporaryAndBackupCanBePutOnInThisBuild() {
    #expect(Buff.allCases.filter(\.isAvailable) == [.temporary, .backup])
    #expect(Buff.allCases.filter(\.refusesProtectedFolders) == [.temporary])
  }

  @MainActor
  @Test func theCapsFaceIsBundledAndRegistered() {
    _ = Caps.font(size: 13)
    #expect(NSFont(name: "BarlowCondensed-SemiBold", size: 13) != nil)
    #expect(NSFont(name: "BarlowCondensed-Medium", size: 13) != nil)
    #expect(NSFont(name: "BarlowCondensed-Bold", size: 13) != nil)
  }
}
