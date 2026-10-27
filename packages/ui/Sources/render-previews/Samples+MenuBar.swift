import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation

/// Made-up folders for the menu-bar popover's states. Not anyone's real data.
extension Samples {
  /// Projects, which macOS stopped DirBuff reading three days ago.
  static let lostAccessReport = FolderReport(
    folder: Folder(
      id: 5, bookmark: Data(), path: "/Users/sample/Projects",
      settings: TemporarySettings(maxAgeDays: 90), wearsTemporary: true,
      accessLostAt: now.addingTimeInterval(-3 * 86_400), createdAt: now, lastRunAt: now),
    reading: .failure(.noAccess))

  /// Exports, on a drive that isn't connected.
  static let unreachableReport = FolderReport(
    folder: Folder(
      id: 6, bookmark: Data(), path: "/Volumes/T7 Shuttle/Exports",
      settings: TemporarySettings(maxAgeDays: 30), wearsTemporary: true, createdAt: now,
      lastRunAt: now),
    reading: .failure(.unreachable))

  /// The popover as the app builds it at `shownAt`, with the folders in `working` clearing.
  static func popover(
    _ licence: Licence,
    reports: [FolderReport] = Samples.reports,
    working: Set<Int64> = []
  ) -> PopoverState {
    PopoverState(
      folders: FolderState.all(reports, licence: licence, working: working, now: shownAt),
      licence: licence, now: shownAt)
  }
}
