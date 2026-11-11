import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation

/// Backup's made-up folders, at `pageMoment` (Sun 25 Oct 2026, 13:37 UTC) in the folder page's
/// home. The app wears these states only once something real produces them.
extension Samples {
  private static func ago(_ seconds: TimeInterval) -> Date {
    pageMoment.addingTimeInterval(-seconds)
  }

  /// What a folder's Backup has done, the way the database reads it.
  static func backupStatus(
    lastSuccess: TimeInterval? = 12 * 60,
    cloudOnly: Int = 0,
    skipped: [SkippedFile] = [],
    failedRuns: Int = 0,
    failingFor: TimeInterval = 0,
    lastError: String? = nil
  ) -> BackupStatus {
    BackupStatus(
      lastRunAt: ago(lastSuccess ?? 60),
      lastSuccessAt: lastSuccess.map(ago),
      lastError: lastError,
      failingSince: failedRuns > 0 ? ago(failingFor) : nil,
      failedRunsInARow: failedRuns,
      skipped: skipped,
      cloudOnlyCount: cloudOnly)
  }

  /// A folder in the sample home that wears Backup, and Temporary too when `temporary` is given.
  static func backupReport(
    id: Int64,
    _ name: String,
    status: BackupStatus? = backupStatus(),
    drive: DriveState = .ready,
    temporary: TemporarySettings? = nil,
    problem: FolderProblem? = nil,
    isPausedByLicence: Bool = false,
    accessLostAt: Date? = nil,
    missingSince: Date? = nil,
    path: String? = nil
  ) -> FolderReport {
    let path = path ?? "\(pageHome)/\(name)"
    var report: FolderReport
    if let temporary {
      report = pageReport(
        id: id, path: path, settings: temporary,
        items: pageFiles(24, in: path, named: "file", age: 5 * 86_400, size: 8_000_000),
        isPausedByLicence: isPausedByLicence, problem: problem, accessLostAt: accessLostAt,
        missingSince: missingSince)
    } else {
      let folder = Folder(
        id: id, bookmark: Data(), path: path, accessLostAt: accessLostAt,
        missingSince: missingSince, createdAt: ago(60 * 86_400))
      report = FolderReport(
        folder: folder,
        location: problem.map { .failure($0) } ?? .success(URL(fileURLWithPath: path)),
        buffs: [])
    }
    let wear = Wear(
      folderID: id, settings: BackupSettings(), isPausedByLicence: isPausedByLicence,
      lastRunAt: ago(30 * 86_400))
    report.buffs.append(
      .backup(wear, problem == nil ? status.map { .success($0) } : nil))
    report.drive = drive
    return report
  }

  /// The run the backup popover, tile and card show: 1.2 of 3.4 GB in.
  static func backupProgress(folder: Int64) -> RunProgress {
    RunProgress(
      folderID: folder, itemsDone: 4_210, itemsTotal: 11_940, bytesDone: 1_200_000_000,
      bytesTotal: 3_400_000_000, current: "IMG_2041.heic")
  }

  static let unreadableFiles = [
    SkippedFile(path: "Taxes/2025.numbers", reason: "Another app has it open"),
    SkippedFile(path: "Taxes/receipts.zip", reason: "DirBuff may not read it"),
    SkippedFile(path: "Notes.sqlite", reason: "Another app has it open"),
  ]

  static let failingStatus = backupStatus(
    lastSuccess: 6 * 3_600, failedRuns: 4, failingFor: 5 * 3_600,
    lastError: "The connection to Google Drive was lost")

  // MARK: - The shelves

  /// A Backup folder in each state of its own: at rest, with files only in iCloud, backing up, with
  /// files it couldn't read, failing, and not backed up for days.
  static var backupOwnStates: [FolderReport] {
    [
      backupReport(id: 1, "Documents", temporary: TemporarySettings(maxAgeDays: 90)),
      backupReport(id: 2, "Pictures", status: backupStatus(lastSuccess: 5 * 60, cloudOnly: 120)),
      backupReport(id: 3, "Desktop"),
      backupReport(id: 4, "Projects", status: backupStatus(skipped: unreadableFiles)),
      backupReport(id: 5, "Music", status: failingStatus),
      backupReport(id: 6, "Movies", status: backupStatus(lastSuccess: 4 * 86_400 + 3_600)),
    ]
  }

  /// A folder for each cause the Google account and its one backup can fail with.
  static var backupDriveStates: [FolderReport] {
    [
      backupReport(
        id: 1, "Documents", status: backupStatus(lastSuccess: 3 * 3_600), drive: .signedOut),
      backupReport(
        id: 2, "Pictures", status: backupStatus(lastSuccess: 3 * 3_600), drive: .full),
      backupReport(id: 3, "Desktop", drive: .backupInBin),
      backupReport(id: 4, "Projects", drive: .backupGone),
      backupReport(id: 5, "Music", drive: .partMissing),
      backupReport(id: 6, "Movies", status: nil, drive: .notSignedIn),
    ]
  }

  /// A folder for each reason a backup waits, and one put on a moment ago.
  static var backupWaitingStates: [FolderReport] {
    [
      backupReport(id: 1, "Documents", drive: .waiting(.internet)),
      backupReport(id: 2, "Pictures", drive: .waiting(.wifi)),
      backupReport(id: 3, "Desktop", drive: .waiting(.power)),
      backupReport(id: 4, "Projects", drive: .waiting(.lowPowerMode)),
      backupReport(
        id: 5, "Music",
        drive: .waiting(.googleLimit(resumesAt: pageMoment.addingTimeInterval(8_000)))),
      backupReport(id: 6, "Movies", status: backupStatus(lastSuccess: nil)),
    ]
  }

  /// A Backup folder DirBuff can't reach, whatever the Google account does.
  static var backupFolderStates: [FolderReport] {
    [
      backupReport(
        id: 1, "Documents", problem: .noAccess, accessLostAt: ago(3 * 86_400 + 120)),
      backupReport(id: 2, "Pictures", problem: .missing, missingSince: ago(2 * 86_400)),
      backupReport(
        id: 3, "Exports", problem: .unreachable, path: "/Volumes/T7 Shuttle/Exports"),
      backupReport(id: 4, "Desktop", temporary: TemporarySettings(maxAgeDays: 30)),
    ]
  }

  /// Backup and Temporary both paused by the licence's end.
  static var backupPausedStates: [FolderReport] {
    [
      backupReport(
        id: 1, "Documents", temporary: TemporarySettings(maxAgeDays: 90), isPausedByLicence: true),
      backupReport(id: 2, "Pictures", isPausedByLicence: true),
    ]
  }

  // MARK: - Pages, popovers and Finder

  /// The main window's state with Backup's progress.
  static func backupShelf(
    _ reports: [FolderReport], licence: Licence = .licensed, backingUp: Set<Int64> = [],
    progress: RunProgress? = nil
  ) -> MainState {
    MainState(
      reports: reports, licence: licence, backingUp: backingUp, backupProgress: progress,
      now: pageMoment, calendar: pageCalendar, binName: binName, home: pageHome,
      startupVolumeName: "Macintosh HD")
  }

  /// The popover as the app builds it at `pageMoment`.
  static func backupPopover(
    _ reports: [FolderReport], backingUp: Set<Int64> = [], progress: RunProgress? = nil
  ) -> PopoverState {
    PopoverState(
      folders: FolderState.all(
        reports, licence: .licensed, backingUp: backingUp, backupProgress: progress,
        now: pageMoment, calendar: pageCalendar, binName: binName, home: pageHome),
      scheduleLines: scheduleLines(reports, now: pageMoment, calendar: pageCalendar),
      backupProgress: progress, licence: .licensed, now: pageMoment, calendar: pageCalendar)
  }

  /// Finder's right-click menu on `folder`, from the rows the app would publish.
  static func backupFinderMenu(_ reports: [FolderReport], folder: String) -> FinderMenu {
    let snapshot = FinderSnapshot(
      folders: FolderState.all(
        reports, licence: .licensed, now: pageMoment, calendar: pageCalendar, binName: binName,
        home: pageHome),
      licence: .licensed, protectedFolderPaths: [], binName: binName)
    return snapshot.menu(for: URL(fileURLWithPath: "\(pageHome)/\(folder)"))
  }
}
