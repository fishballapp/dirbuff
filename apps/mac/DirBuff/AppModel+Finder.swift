import DirBuffKit
import DirBuffUI
import Foundation

extension AppModel {
  /// Hands the Finder extension what its badge and item need: the Temporary folders, every added
  /// folder, and the protected ones it offers nothing on. The protected list changes as volumes
  /// mount.
  func publishForFinder(_ reports: [FolderReport]) {
    guard let shared = FinderFolders.defaults else { return }
    let temporaryPaths = reports.filter { $0.folder.wearsTemporary }.map(\.folder.path)
    if shared.temporaryFolderPaths != temporaryPaths {
      shared.temporaryFolderPaths = temporaryPaths
    }
    let addedPaths = reports.map(\.folder.path)
    if shared.addedFolderPaths != addedPaths {
      shared.addedFolderPaths = addedPaths
    }
    let protectedPaths = System.protectedFolderPaths()
    if shared.protectedFolderPaths != protectedPaths {
      shared.protectedFolderPaths = protectedPaths
    }
  }
}
