import DirBuffKit
import DirBuffUI
import Foundation

/// The Documents folder's backups as the backup page shows them: six kept, the newest a quarter
/// of an hour old and the oldest from the spring; Finance/2026 three columns deep; a file changed
/// several times and one never.
extension Samples {
  static let browserDocuments = "\(pageHome)/Documents"

  private static func backup(_ id: String, ago: TimeInterval) -> KeptBackup {
    KeptBackup(id: id, savedAt: pageMoment.addingTimeInterval(-ago))
  }

  static let browserBackups: [KeptBackup] = [
    backup("b6", ago: 14 * 60),
    backup("b5", ago: 5 * 3_600 + 20 * 60),
    backup("b4", ago: 86_400 + 2 * 3_600),
    backup("b3", ago: 6 * 86_400 + 4 * 3_600),
    backup("b2", ago: 24 * 86_400 + 7 * 3_600),
    backup("b1", ago: 196 * 86_400 + 3 * 3_600),
  ]

  static var latestBackup: KeptBackup { browserBackups[0] }
  static var firstBackup: KeptBackup { browserBackups[5] }
  static var olderBackup: KeptBackup { browserBackups[4] }

  private static func file(
    _ path: String, _ size: Int64, _ sinceThen: BackupItem.SinceThen? = nil
  ) -> BackupItem {
    BackupItem(path: path, kind: .file, size: size, sinceThen: sinceThen)
  }

  private static func folder(_ path: String, _ sinceThen: BackupItem.SinceThen? = nil)
    -> BackupItem
  {
    BackupItem(path: path, kind: .folder, sinceThen: sinceThen)
  }

  /// The top of Documents in the latest backup: as it is on the Mac, but for the one file
  /// edited since.
  static let latestTop: [BackupItem] = [
    folder("Finance"), folder("Letters"), folder("Photos to sort"),
    file("Lease-2026.pdf", 1_400_000), file("Mei-CV-2026.pages", 2_800_000),
    file("notes.txt", 4_200), file("Wedding speech.docx", 88_000, .changed),
  ]

  /// The top of Documents in the backup from 24 days ago: two files deleted since, others changed.
  static let olderTop: [BackupItem] = [
    file("Draft chapter 3.docx", 214_000, .deleted), folder("Finance", .changed),
    folder("Letters"), file("Mei-CV-2026.pages", 2_700_000, .changed),
    file("notes.txt", 4_100, .changed), file("Old budget.numbers", 1_900_000, .deleted),
    file("Wedding speech.docx", 62_000, .changed),
  ]

  static let finance: [BackupItem] = [
    folder("Finance/2025"), folder("Finance/2026"), file("Finance/Receipts.xlsx", 310_000),
  ]

  static let finance2026: [BackupItem] = [
    file("Finance/2026/Bank statement Oct.pdf", 240_000),
    file("Finance/2026/Flat viewing.mov", 2_400_000_000),
    file("Finance/2026/Lease-2026.pdf", 1_400_000),
    file("Finance/2026/Tax return 2025–26.pdf", 640_000),
  ]

  /// The lease's history: changed three times, and the content from before the first change.
  static var leaseHistory: FileHistory {
    let path = "Finance/2026/Lease-2026.pdf"
    let b = browserBackups
    return FileHistory(
      path: path,
      versions: [
        BackupVersion(
          path: path, snapshotID: b[5].id, savedAt: b[5].savedAt, change: .changed, size: nil,
          replacedAt: b[4].savedAt),
        BackupVersion(
          path: path, snapshotID: b[4].id, savedAt: b[4].savedAt, change: .changed,
          size: 1_200_000),
        BackupVersion(
          path: path, snapshotID: b[2].id, savedAt: b[2].savedAt, change: .changed,
          size: 1_400_000),
        BackupVersion(
          path: path, snapshotID: b[1].id, savedAt: b[1].savedAt, change: .changed,
          size: 1_400_000),
      ], trackedSince: firstBackup.savedAt)
  }

  /// The page as it opens: the latest backup, its top listed, nothing selected.
  static var browserOpen: BackupBrowserState {
    var state = BackupBrowserState(
      folderName: "Documents", folderPath: browserDocuments, backups: .loaded(browserBackups))
    state.didList(BackupPlace(backupID: latestBackup.id, path: ""), latestTop)
    return state
  }

  /// Three columns deep in the latest backup, the lease selected with its timeline.
  static var browserDeep: BackupBrowserState {
    var state = browserOpen
    let latest = latestBackup.id
    state.didList(BackupPlace(backupID: latest, path: "Finance"), finance)
    state.didList(BackupPlace(backupID: latest, path: "Finance/2026"), finance2026)
    state.select(finance2026[2])
    state.histories[finance2026[2].path] = leaseHistory
    return state
  }

  /// A file that never changed: the timeline is one sentence.
  static var browserUnchanged: BackupBrowserState {
    var state = browserDeep
    state.select(finance2026[0])
    state.histories[finance2026[0].path] = FileHistory(
      path: finance2026[0].path, versions: [], trackedSince: firstBackup.savedAt)
    return state
  }

  /// The backup from 24 days ago, with a file deleted since selected.
  static var browserOlderDeleted: BackupBrowserState {
    var state = browserOpen
    state.selectBackup(olderBackup.id)
    state.didList(BackupPlace(backupID: olderBackup.id, path: ""), olderTop)
    state.select(olderTop[5])
    state.histories[olderTop[5].path] = FileHistory(
      path: olderTop[5].path,
      versions: [
        BackupVersion(
          path: olderTop[5].path, snapshotID: browserBackups[5].id,
          savedAt: browserBackups[5].savedAt, change: .changed, size: nil,
          replacedAt: browserBackups[4].savedAt),
        BackupVersion(
          path: olderTop[5].path, snapshotID: browserBackups[4].id,
          savedAt: browserBackups[4].savedAt, change: .changed, size: 1_900_000),
        BackupVersion(
          path: olderTop[5].path, snapshotID: browserBackups[3].id,
          savedAt: browserBackups[3].savedAt, change: .removed, size: nil),
      ], trackedSince: firstBackup.savedAt)
    return state
  }

  /// A folder selected: its contents in the next column.
  static var browserFolder: BackupBrowserState {
    var state = browserOpen
    state.didList(BackupPlace(backupID: latestBackup.id, path: "Finance"), finance)
    state.select(latestTop[0])
    return state
  }

  /// Finance opened, its column still coming from Google Drive.
  static var browserLoading: BackupBrowserState {
    var state = browserOpen
    state.select(latestTop[0])
    state.listings[BackupPlace(backupID: latestBackup.id, path: "Finance")] = .loading
    return state
  }

  /// Finance opened while a backup runs: the column says what it waits for.
  static var browserWaiting: BackupBrowserState {
    var state = browserLoading
    state.busyWith = .backup
    return state
  }

  /// A file's restore and a drag to Finder queued behind the weekly check.
  static var browserRestoreWaiting: BackupBrowserState {
    var state = browserOlderDeleted
    state.busyWith = .check
    state.dragsInFlight = 1
    state.restores[BackupPlace(backupID: olderBackup.id, path: "Old budget.numbers")] = .restoring(
      RestoreRun(folderName: "Old budget.numbers", path: "\(browserDocuments)/Old budget.numbers"))
    return state
  }

  /// Offline: the lease's older backup can't be listed, and its timeline, which is local, shows.
  static var browserOffline: BackupBrowserState {
    var state = browserDeep
    guard let entry = state.timeline(now: pageMoment, calendar: pageCalendar)?.entries[2] else {
      fail("The lease has no third version")
    }
    state.show(entry)
    let problem = RestoreProblem(DriveProblem.unreachable, while: .listing)
    state.listings[BackupPlace(backupID: entry.backupID, path: "")] = .failed(problem)
    return state
  }

  /// Finance from the older backup coming back.
  static var browserRestoring: BackupBrowserState {
    var state = browserOpen
    state.selectBackup(olderBackup.id)
    state.didList(BackupPlace(backupID: olderBackup.id, path: ""), olderTop)
    state.didList(BackupPlace(backupID: olderBackup.id, path: "Finance"), finance)
    state.select(olderTop[1])
    state.restores[BackupPlace(backupID: olderBackup.id, path: "Finance")] = .restoring(
      RestoreRun(
        folderName: "Finance", path: "\(browserDocuments)/Finance",
        progress: decodeProgress(
          #"{"percent_done":0.35,"total_files":214,"files_restored":61,"total_bytes":182000000,"bytes_restored":64000000}"#
        )))
    return state
  }

  /// The deleted budget back where it was.
  static var browserRestored: BackupBrowserState {
    var state = browserOlderDeleted
    state.restores[BackupPlace(backupID: olderBackup.id, path: "Old budget.numbers")] = .done(
      path: "\(browserDocuments)/Old budget.numbers")
    return state
  }

  /// A backup this Mac took over and hasn't backed up into yet: the timeline claims nothing.
  static var browserTakenOver: BackupBrowserState {
    var state = browserDeep
    state.select(finance2026[0])
    state.histories[finance2026[0].path] = FileHistory(path: finance2026[0].path, versions: [])
    return state
  }

  /// Finance on this Mac can't be read (macOS's privacy refusal): no marks, and Restore says
  /// what it does either way.
  static var browserUnreadable: BackupBrowserState {
    var state = browserOpen
    let latest = latestBackup.id
    state.didList(
      BackupPlace(backupID: latest, path: "Finance"),
      finance.map { BackupItem(path: $0.path, kind: $0.kind, size: $0.size, sinceThen: .unknown) })
    state.select(
      BackupItem(path: "Finance/Receipts.xlsx", kind: .file, size: 310_000, sinceThen: .unknown))
    state.histories["Finance/Receipts.xlsx"] = FileHistory(
      path: "Finance/Receipts.xlsx", versions: [], trackedSince: firstBackup.savedAt)
    return state
  }

  /// Documents in the Bin: its backups browse as ever, unmarked, and Restore asks where.
  static var browserAway: BackupBrowserState {
    var state = BackupBrowserState(
      folderName: "Documents", folderPath: browserDocuments, backups: .loaded(browserBackups))
    state.isFolderAway = true
    let unmarked = { (items: [BackupItem]) in
      items.map { BackupItem(path: $0.path, kind: $0.kind, size: $0.size, sinceThen: .unknown) }
    }
    let latest = latestBackup.id
    state.didList(BackupPlace(backupID: latest, path: ""), unmarked(latestTop))
    state.didList(BackupPlace(backupID: latest, path: "Finance"), unmarked(finance))
    state.didList(BackupPlace(backupID: latest, path: "Finance/2026"), unmarked(finance2026))
    state.select(finance2026[2])
    state.histories[finance2026[2].path] = leaseHistory
    return state
  }

  /// A 2.4 GB film: too big for Quick Look.
  static var browserTooBig: BackupBrowserState {
    var state = browserDeep
    state.select(finance2026[1])
    state.histories[finance2026[1].path] = FileHistory(
      path: finance2026[1].path, versions: [], trackedSince: firstBackup.savedAt)
    return state
  }

  private static func decodeProgress(_ json: String) -> RestoreProgress {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do {
      return try decoder.decode(RestoreProgress.self, from: Data(json.utf8))
    } catch {
      fail("A preview's progress didn't decode: \(error)")
    }
  }
}
