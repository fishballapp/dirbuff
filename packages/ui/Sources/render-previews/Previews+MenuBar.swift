import DirBuffUI
import SwiftUI

/// The menu-bar window's states.
@MainActor
func menuBarPreviews() -> [Preview] {
  [
    (
      "menubar-busy",
      AnyView(MenuBarView(state: Samples.busy)),
      nil
    ),
    (
      "menubar-last-minute",
      AnyView(MenuBarView(state: Samples.lastMinute)),
      nil
    ),
    (
      "menubar-quiet",
      AnyView(MenuBarView(state: Samples.quiet)),
      nil
    ),
    (
      "menubar-nofolders",
      AnyView(MenuBarView(state: Samples.noFolders)),
      nil
    ),
    (
      "menubar-extensionoff",
      AnyView(MenuBarView(state: Samples.extensionOff)),
      nil
    ),
    (
      "menubar-trial",
      AnyView(MenuBarView(state: Samples.menuBar(.trial(daysLeft: 9)))),
      nil
    ),
    (
      "menubar-trial-ended",
      AnyView(MenuBarView(state: Samples.menuBar(.trialEnded))),
      nil
    ),
    (
      "menubar-ended",
      AnyView(MenuBarView(state: Samples.menuBar(Samples.ended))),
      nil
    ),
    (
      "menubar-kept",
      AnyView(MenuBarView(state: Samples.menuBar(Samples.kept))),
      nil
    ),
    (
      "menubar-paused",
      AnyView(MenuBarView(state: Samples.menuBar(.paused))),
      nil
    ),
  ]
}
