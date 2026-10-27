import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation

extension AppModel {
  /// Hands the Finder extension what its badge and right-click menu need: each folder's mark and
  /// buffs, the protected folders Temporary never clears, and the Bin's name. Written only when the
  /// encoded snapshot changes.
  func publishForFinder() {
    guard let shared = FinderFolders.defaults else { return }
    shared.snapshot = FinderSnapshot(
      folders: folders(now: Date()),
      licence: licence,
      protectedFolderPaths: System.protectedFolderPaths(),
      binName: SystemBin.name
    )
  }
}
