import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation
import SwiftUI

/// Made-up files for the folder's files page: a Downloads that clears what is older than 14 days,
/// drawn on Sun 25 Oct 2026, 13:37 UTC, so the next clean-up is Monday's at 14:00.
extension Samples {
  private static let filesMoment = now.addingTimeInterval(10 * 86_400 + 5 * 3_600 + 37 * 60)
  private static let filesDay: TimeInterval = 86_400
  private static let filesCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    calendar.locale = Locale(identifier: "en_GB")
    return calendar
  }()
  private static let filesSettings = TemporarySettings(maxAgeDays: 14)
  private static let filesDownloadsPath = "\(NSHomeDirectory())/Downloads"

  /// A file that goes at the clean-up after `goesAt`: added 14 days before it.
  private static func upcomingFile(_ name: String, size: Int64, goesAt: Date) -> Upcoming {
    Upcoming(
      item: Item(
        url: URL(fileURLWithPath: "\(filesDownloadsPath)/\(name)"),
        freshness: goesAt.addingTimeInterval(-14 * filesDay), size: size),
      date: goesAt)
  }

  /// Mon 26 Oct, 13:20 to 13:50: twelve files that go at 14:00.
  private static let mondaysFiles: [Upcoming] = [
    ("Figma-Installer.dmg", 312_000_000), ("Q3-report-final-v3.pdf", 4_100_000),
    ("zoom_bundle.zip", 880_000_000), ("IMG_4471.HEIC", 3_200_000),
    ("IMG_4472.HEIC", 3_400_000), ("IMG_4473.HEIC", 2_900_000), ("notes-export.txt", 48_000),
    ("receipt-oct.pdf", 210_000), ("slides-v2.key", 62_000_000), ("tickets.pdf", 380_000),
    ("train-times.png", 1_100_000), ("wallpaper-4k.jpg", 9_800_000),
  ].enumerated().map { index, file in
    upcomingFile(
      file.0, size: Int64(file.1),
      goesAt: filesMoment.addingTimeInterval(filesDay - 17 * 60 + Double(index) * 150))
  }

  /// Wed 28 Oct: four files that go at 14:00, 15:00, 16:00 and 17:00.
  private static let wednesdaysFiles: [Upcoming] = [
    ("brochure-draft.pdf", 2_400_000), ("Design-assets.zip", 192_000_000),
    ("logo-options.png", 640_000), ("invoice-1042.pdf", 120_000),
  ].enumerated().map { index, file in
    upcomingFile(
      file.0, size: Int64(file.1),
      goesAt: filesMoment.addingTimeInterval(3 * filesDay - 17 * 60 + Double(index) * 3_600))
  }

  /// Thu 29 Oct onwards: thirty-seven screenshots, one every few hours.
  private static let laterFiles: [Upcoming] = (0..<37).map { index in
    upcomingFile(
      "Screenshot 2026-10-\(String(format: "%02d", 15 + index / 3)) at \(9 + index % 9).\(10 + index).png",
      size: 1_200_000 + Int64(index) * 31_000,
      goesAt: filesMoment.addingTimeInterval(4 * filesDay + Double(index) * 5 * 3_600))
  }

  private static func filesFolder(
    _ settings: TemporarySettings = filesSettings,
    path: String = filesDownloadsPath,
    accessLostAt: Date? = nil,
    missingSince: Date? = nil
  ) -> Folder {
    Folder(
      id: 1, bookmark: Data(), path: path, settings: settings, wearsTemporary: true,
      accessLostAt: accessLostAt, missingSince: missingSince, createdAt: now,
      lastRunAt: filesMoment.addingTimeInterval(-37 * 60))
  }

  private static func filesStatus(
    items: [Item] = [], upcoming: [Upcoming] = []
  ) -> Engine.FolderStatus {
    Engine.FolderStatus(
      url: URL(fileURLWithPath: filesDownloadsPath), wearsTemporary: true, isProtectedRoot: false,
      items: items + upcoming.map(\.item), dueNow: [], upcoming: upcoming)
  }

  private static func filesState(
    _ reading: Result<Engine.FolderStatus, FolderProblem>,
    settings: TemporarySettings = filesSettings,
    licence: Licence = .licensed,
    folder: Folder? = nil
  ) -> MainState {
    MainState(
      reports: [FolderReport(folder: folder ?? filesFolder(settings), reading: reading)]
        + reports.dropFirst().prefix(2),
      licence: licence, now: filesMoment, calendar: filesCalendar, binName: binName,
      home: NSHomeDirectory(), startupVolumeName: "Macintosh HD")
  }

  /// Twelve files go tomorrow at 14:00, four on Wednesday, thirty-seven later.
  static var filesToGo: MainState {
    filesState(.success(filesStatus(upcoming: mondaysFiles + wednesdaysFiles + laterFiles)))
  }

  /// Four files go at the next clean-up and nothing after: one group.
  static var filesOneGroup: MainState {
    filesState(.success(filesStatus(upcoming: Array(mondaysFiles.prefix(4)))))
  }

  /// Empty on restart: everything dated goes at the first clean-up after one.
  static var filesAtRestart: MainState {
    filesState(
      .success(filesStatus(items: mondaysFiles.map(\.item))),
      settings: TemporarySettings(rule: .emptyOnRestart))
  }

  /// Files that nothing is due to take.
  static var filesNothingNext: MainState {
    filesState(
      .success(filesStatus(items: Array(mondaysFiles.prefix(3)).map(\.item))))
  }

  /// macOS took away access three days ago.
  static var filesCantRead: MainState {
    filesState(
      .failure(.noAccess),
      folder: filesFolder(accessLostAt: filesMoment.addingTimeInterval(-3 * filesDay)))
  }

  /// Moved to the Bin on Thu 22 Oct.
  static var filesMissing: MainState {
    filesState(
      .failure(.missing),
      folder: filesFolder(
        path: "\(NSHomeDirectory())/Projects",
        missingSince: filesMoment.addingTimeInterval(-3 * filesDay - 3 * 3_600)))
  }

  /// On a drive that isn't connected.
  static var filesUnplugged: MainState {
    filesState(.failure(.unreachable), folder: filesFolder(path: "/Volumes/T7 Shuttle/Downloads"))
  }

  static var filesPaused: MainState {
    filesState(.success(filesStatus(upcoming: mondaysFiles)), licence: .trialEnded)
  }

  /// Draws the files page for folder 1 from `state`, as the app's `MainContainerView` does.
  static func filesDestination(_ state: MainState) -> (MainRoute) -> AnyView {
    { route in
      guard case .files(let id) = route, let folder = state.folders.first(where: { $0.id == id })
      else { return AnyView(EmptyView()) }
      return AnyView(
        FolderFilesPage(
          folder: folder, binName: binName,
          folderState: state.shelfFolders.first { $0.id == id }, now: filesMoment,
          isPaused: !state.mayClean))
    }
  }
}
