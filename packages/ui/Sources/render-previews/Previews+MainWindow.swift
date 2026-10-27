import DirBuffUI
import SwiftUI

/// The main window's states, at one window size.
@MainActor
func mainWindowPreviews() -> [Preview] {
  let mainSize = CGSize(width: 760, height: 560)
  return [
    (
      "main-overview",
      AnyView(
        MainView(state: Samples.main, selection: .constant(.overview), binName: Samples.binName)),
      mainSize
    ),
    (
      "main-folder-on",
      AnyView(
        MainView(state: Samples.main, selection: .constant(.folder(1)), binName: Samples.binName)),
      mainSize
    ),
    (
      "main-folder-off",
      AnyView(
        MainView(state: Samples.main, selection: .constant(.folder(4)), binName: Samples.binName)),
      mainSize
    ),
    (
      "main-overview-trial",
      AnyView(
        MainView(
          state: Samples.main(.trial(daysLeft: 9)), selection: .constant(.overview),
          binName: Samples.binName)),
      mainSize
    ),
    (
      "main-overview-licence-ended",
      AnyView(
        MainView(
          state: Samples.main(Samples.ended), selection: .constant(.overview),
          binName: Samples.binName)),
      mainSize
    ),
    (
      "main-overview-licence-kept",
      AnyView(
        MainView(
          state: Samples.main(Samples.kept), selection: .constant(.overview),
          binName: Samples.binName)),
      mainSize
    ),
    (
      "main-folder-licence-ended",
      AnyView(
        MainView(
          state: Samples.main(Samples.ended), selection: .constant(.folder(4)),
          binName: Samples.binName)),
      mainSize
    ),
  ]
}
