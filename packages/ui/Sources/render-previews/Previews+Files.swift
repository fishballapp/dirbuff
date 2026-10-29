import DirBuffUI
import SwiftUI

/// A folder's files: what is cleared next, grouped by when, and each way it has nothing to list.
@MainActor
func filesPreviews() -> [Preview] {
  let size = CGSize(width: 1240, height: 640)
  func page(_ name: String, _ state: MainState, height: CGFloat = 640) -> Preview {
    (
      name,
      AnyView(
        MainView(
          state: state, navigation: .constant(MainNavigation(opening: .files(1))),
          destination: Samples.filesDestination(state))),
      CGSize(width: size.width, height: height)
    )
  }
  return [
    page("files-temporary", Samples.filesToGo),
    page("files-one-group", Samples.filesOneGroup, height: 420),
    page("files-at-restart", Samples.filesAtRestart, height: 420),
    page("files-nothing-next", Samples.filesNothingNext, height: 420),
    page("files-cant-read", Samples.filesCantRead, height: 420),
    page("files-missing", Samples.filesMissing, height: 420),
    page("files-unplugged", Samples.filesUnplugged, height: 420),
    page("files-paused", Samples.filesPaused, height: 420),
  ]
}
