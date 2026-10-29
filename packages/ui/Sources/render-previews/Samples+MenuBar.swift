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

  /// Documents, which was moved to the Bin two days ago.
  static let missingReport = FolderReport(
    folder: Folder(
      id: 7, bookmark: Data(), path: "/Users/sample/Documents",
      settings: TemporarySettings(maxAgeDays: 90), wearsTemporary: true,
      missingSince: now.addingTimeInterval(-2 * 86_400), createdAt: now, lastRunAt: now),
    reading: .failure(.missing))

  /// The run the working popover shows: 3 of 12 items in, one with a name too long for the line.
  static func progress(folder: Int64 = 1, current: String = "zoom_bundle.zip") -> Engine.RunProgress
  {
    Engine.RunProgress(
      folderID: folder, itemsDone: 3, itemsTotal: 12, bytesDone: 410_000_000,
      bytesTotal: 1_300_000_000, current: current)
  }

  /// The popover as the app builds it at `shownAt`, with the folders in `working` clearing.
  static func popover(
    _ licence: Licence,
    reports: [FolderReport] = Samples.reports,
    working: Set<Int64> = [],
    progress: Engine.RunProgress? = nil
  ) -> PopoverState {
    PopoverState(
      folders: FolderState.all(
        reports, licence: licence, working: working, progress: progress, now: shownAt),
      reports: reports, progress: progress, licence: licence, now: shownAt)
  }
}
