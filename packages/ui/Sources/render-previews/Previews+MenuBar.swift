import DirBuffCore
import DirBuffUI
import SwiftUI

/// The menu-bar popover in each state, and the glyph in each state on a light and a dark menu bar.
@MainActor
func menuBarPreviews() -> [Preview] {
  [
    (
      "popover-rest",
      AnyView(MenuBarView(state: Samples.popover(.licensed))),
      nil
    ),
    (
      "popover-working",
      AnyView(
        MenuBarView(
          state: Samples.popover(.licensed, working: [1], progress: Samples.progress()))),
      nil
    ),
    (
      "popover-working-long-name",
      AnyView(
        MenuBarView(
          state: Samples.popover(
            .licensed, working: [1],
            progress: Samples.progress(
              current: "Screenshot 2026-09-01 at 10.12.34 (a very long name that cannot fit).png")))
      ),
      nil
    ),
    (
      "popover-working-starting",
      AnyView(MenuBarView(state: Samples.popover(.licensed, working: [1]))),
      nil
    ),
    (
      "popover-needs-you",
      AnyView(
        MenuBarView(
          state: Samples.popover(.licensed, reports: Samples.reports + [Samples.lostAccessReport]))),
      nil
    ),
    (
      "popover-missing",
      AnyView(
        MenuBarView(
          state: Samples.popover(.licensed, reports: Samples.reports + [Samples.missingReport]))),
      nil
    ),
    (
      "popover-paused",
      AnyView(
        MenuBarView(
          state: Samples.popover(.licensed, reports: Samples.reports + [Samples.unreachableReport]))
      ),
      nil
    ),
    (
      "popover-trial",
      AnyView(MenuBarView(state: Samples.popover(.trial(daysLeft: 9)))),
      nil
    ),
    (
      "popover-trial-ended",
      AnyView(MenuBarView(state: Samples.popover(.trialEnded))),
      nil
    ),
    (
      "popover-licence-ended",
      AnyView(MenuBarView(state: Samples.popover(Samples.ended))),
      nil
    ),
    (
      "menubar-glyphs",
      AnyView(MenuBarGlyphSheet()),
      nil
    ),
  ]
}

/// The three glyphs as a menu bar draws them: a template image, so white on a dark bar and black on
/// a light one.
struct MenuBarGlyphSheet: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let isDark = colorScheme == .dark
    HStack(spacing: 28) {
      ForEach(MenuBarGlyphState.allCases, id: \.self) { state in
        Image(nsImage: MenuBarGlyph.image(state))
          .renderingMode(.template)
          .foregroundStyle(isDark ? Color.white : Color.black)
      }
    }
    .frame(width: 280, height: 24)
    .background(isDark ? Color(white: 0.16) : Color(white: 0.93))
  }
}
