import DirBuffCore
import DirBuffKit
import DirBuffUI
import SwiftUI

/// Restore in the app: Show Versions…, Restore a Copy, Restore Folder, Restore from Google Drive
/// with Keep Backing Up Here, the password prompt and every failure a restore can read as.
@MainActor
func restorePreviews() -> [Preview] {
  let full = CGSize(width: 1240, height: 800)
  let tall = CGSize(width: 1240, height: 900)
  let documentsPath = "\(Samples.pageHome)/Documents"
  let documents = RestoreFolderState(folderName: "Documents", folderPath: documentsPath)

  func versionsWindow(
    _ state: VersionsState, tab: VersionsState.Tab = .onThisMac, query: String = "",
    selected: String? = nil, version: String? = nil, copying: String? = nil,
    toast: VersionsToast? = nil
  ) -> AnyView {
    AnyView(
      MainView(
        state: Samples.backupShelf(Samples.backupLiveShelf),
        navigation: .constant(MainNavigation(opening: .versions(1))),
        page: { _ in
          AnyView(
            VersionsPage(
              state: state, tab: tab, query: query, selectedPath: selected,
              selectedVersionID: version, copyingID: copying, toast: toast))
        }))
  }

  func alert(_ error: any Error, _ subject: RestoreProblem.Subject) -> (AnyView, CGSize?) {
    let alert = BackupAlert.restoreProblem(RestoreProblem(error, while: subject))
    return (AnyView(AlertSnapshot(alert: alert)), AlertSnapshot.size(of: alert))
  }

  /// Each sheet opens as the app opens it, loading, and is told its step afterwards: a preview
  /// that starts at the step could hide what a sheet makes of arriving there.
  func folderSheet(_ step: RestoreFolderState.Step, password: String = "") -> AnyView {
    AnyView(FolderSheetArriving(step: step, folderPath: documentsPath, password: password))
  }

  func driveSheet(
    _ step: RestoreFromDriveState.Step, mac: BackedUpMac? = Samples.oldMac,
    restored: [RestoredFolder] = [], password: String = ""
  ) -> AnyView {
    AnyView(
      DriveSheetArriving(
        step: step, mac: mac, restored: restored, password: password))
  }

  let versions = Samples.versions
  let lease = versions.files.first { $0.name == "Lease-2026.pdf" }
  let removed = versions.files.first { $0.isDeleted }
  let notKept = versions.files.first { $0.hasEarlierVersionNotKept }
  let secondOfLease = lease?.versions.dropFirst().first?.id
  let rowOfRemoved = removed?.versions.first { $0.canRestore }?.id

  let dates = Samples.restoreDates
  let pick = FolderPick(
    folders: Samples.backedUpFolders, destination: Samples.pageHome,
    destinationName: "~")
  let restoring = RestoreRun(
    folderName: "Documents", path: documentsPath, progress: Samples.restoreProgress)
  let restoredFolder = RestoredFolder(
    name: "Documents (20 Oct 2026)", path: documentsPath, source: Samples.backedUpFolders[0])

  let nothing = alert(BackupBuff.Failure.nothingToRestore, .copy(name: "Lease-2026.pdf"))
  let missing = alert(
    BackupBuff.Failure.notInBackup("Finance/Receipts.xlsx"), .copy(name: "Receipts.xlsx"))
  let noRoom = alert(
    BackupBuff.Failure.notEnoughRoom(needed: 1_400_000, available: 320_000),
    .copy(name: "Lease-2026.pdf"))
  let outside = alert(
    BackupBuff.Failure.outsideFolder("Documents/Finance"), .copy(name: "Receipts.xlsx"))
  let offline = alert(DriveProblem.unreachable, .copy(name: "Lease-2026.pdf"))
  let signedOut = alert(DriveProblem.signedOut, .copy(name: "Lease-2026.pdf"))
  let driveFull = alert(BackupBuff.Failure.accountProblem(.full), .copy(name: "Lease-2026.pdf"))
  let gone = alert(BackupBuff.Failure.accountProblem(.backupGone), .copy(name: "Lease-2026.pdf"))
  let inBin = alert(BackupBuff.Failure.accountProblem(.backupInBin), .copy(name: "Lease-2026.pdf"))
  let keychain = alert(BackupBuff.Failure.passwordNeeded, .copy(name: "Lease-2026.pdf"))
  let otherAccount = alert(
    BackupBuff.Failure.accountProblem(.otherAccount), .copy(name: "Lease-2026.pdf"))
  let unconfirmed = alert(
    BackupBuff.Failure.accountProblem(.unconfirmed), .copy(name: "Lease-2026.pdf"))

  let rooms = RestoreProblem(
    BackupBuff.Failure.notEnoughRoom(needed: 48_000_000_000, available: 12_300_000_000),
    while: .folder(name: "Documents"))
  let cannotWrite = RestoreProblem(
    BackupBuff.Failure.cannotWrite(URL(fileURLWithPath: "/Volumes")),
    while: .folder(name: "T7"))

  let previews: [Preview] = [
    // Show Versions…
    ("restore-card", pageWithCard(), tall),
    (
      "restore-versions-list",
      versionsWindow(versions, selected: lease?.path, version: secondOfLease), full
    ),
    ("restore-versions-none-selected", versionsWindow(versions), full),
    (
      "restore-versions-earlier-not-kept",
      versionsWindow(
        versions, selected: "Tax return 2025–26.pdf", version: notKept?.versions.first?.id), full
    ),
    (
      "restore-versions-deleted",
      versionsWindow(versions, tab: .deleted, selected: removed?.path, version: rowOfRemoved), full
    ),
    (
      "restore-versions-copying",
      versionsWindow(
        versions, selected: lease?.path, version: secondOfLease, copying: secondOfLease), full
    ),
    (
      "restore-versions-copied",
      versionsWindow(
        versions, selected: lease?.path, version: secondOfLease,
        toast: VersionsToast(
          url: URL(fileURLWithPath: "\(documentsPath)/Lease-2026 (20 Oct 2026, 18.40).pdf"))), full
    ),
    (
      "restore-versions-no-match",
      versionsWindow(versions, query: "passport"), full
    ),
    (
      "restore-versions-none-yet",
      versionsWindow(
        VersionsState(
          folderID: 1, folderName: "Documents", folderPath: documentsPath, histories: [],
          now: Samples.pageMoment, calendar: Samples.pageCalendar)), full
    ),
    (
      "restore-show-files",
      AnyView(
        MainView(
          state: Samples.backupShelf(Samples.backupOwnStates),
          navigation: .constant(MainNavigation(opening: .unreadFiles(4))),
          page: { _ in
            AnyView(
              UnreadFilesPage(
                state: UnreadFilesState(Samples.backupOwnStates[3]), folderName: "Projects",
                folderPath: "\(Samples.pageHome)/Projects"))
          })), full
    ),

    // Restore a Copy: what stops it.
    ("restore-alert-nothing", nothing.0, nothing.1),
    ("restore-alert-not-in-backup", missing.0, missing.1),
    ("restore-alert-no-room", noRoom.0, noRoom.1),
    ("restore-alert-outside-folder", outside.0, outside.1),
    ("restore-alert-offline", offline.0, offline.1),
    ("restore-alert-signed-out", signedOut.0, signedOut.1),
    ("restore-alert-drive-full", driveFull.0, driveFull.1),
    ("restore-alert-backup-gone", gone.0, gone.1),
    ("restore-alert-backup-in-bin", inBin.0, inBin.1),
    ("restore-alert-password-copy", keychain.0, keychain.1),
    ("restore-alert-other-account", otherAccount.0, otherAccount.1),
    ("restore-alert-unconfirmed", unconfirmed.0, unconfirmed.1),

    // Restore Folder.
    ("restore-folder-loading", folderSheet(.loading), nil),
    ("restore-folder-choose", folderSheet(.choose(dates)), nil),
    ("restore-folder-restoring", folderSheet(.restoring(restoring)), nil),
    (
      "restore-folder-starting",
      folderSheet(.restoring(RestoreRun(folderName: "Documents", path: documentsPath))), nil
    ),
    (
      "restore-folder-done",
      folderSheet(.done(name: "Documents (20 Oct 2026)", path: documentsPath)), nil
    ),
    ("restore-folder-no-room", folderSheet(.failed(rooms)), nil),
    ("restore-folder-cannot-write", folderSheet(.failed(cannotWrite)), nil),
    (
      "restore-folder-password",
      folderSheet(.password(PasswordAsk(macName: "This Mac", isForRestoreFolder: true))), nil
    ),
    (
      "restore-folder-password-wrong",
      folderSheet(
        .password(PasswordAsk(macName: "This Mac", isWrong: true, isForRestoreFolder: true)),
        password: "orange kettle"),
      nil
    ),

    // Restore from Google Drive…
    (
      "restore-sign-in-ask", AnyView(GoogleSignInSheet(state: GoogleSignInState(reason: .restore))),
      nil
    ),
    (
      "restore-sign-in-account",
      AnyView(
        GoogleSignInSheet(
          state: GoogleSignInState(
            reason: .restore, step: .signedIn(account: Samples.backupAccount)))), nil
    ),
    ("restore-drive-loading", driveSheet(.loadingMacs, mac: nil), nil),
    (
      "restore-drive-macs",
      driveSheet(.macs([Samples.oldMac, Samples.thisMac]), mac: nil), nil
    ),
    ("restore-drive-no-backups", driveSheet(.macs([]), mac: nil), nil),
    (
      "restore-drive-password",
      driveSheet(.password(PasswordAsk(macName: "Mei’s MacBook Pro"))), nil
    ),
    (
      "restore-drive-password-wrong",
      driveSheet(
        .password(PasswordAsk(macName: "Mei’s MacBook Pro", isWrong: true)),
        password: "orange kettle"), nil
    ),
    ("restore-drive-folders-loading", driveSheet(.loadingFolders), nil),
    ("restore-drive-folders", driveSheet(.folders(pick)), nil),
    ("restore-drive-restoring", driveSheet(.restoring(restoring)), nil),
    ("restore-drive-restored", driveSheet(.restored, restored: [restoredFolder]), nil),
    (
      "restore-drive-restored-this-mac",
      driveSheet(.restored, mac: Samples.thisMac, restored: [restoredFolder]), nil
    ),
    (
      "restore-drive-restored-twice",
      driveSheet(
        .restored,
        restored: [
          RestoredFolder(
            name: "Documents (8 Apr 2026)", path: "\(Samples.pageHome)/Documents (8 Apr 2026)",
            source: Samples.backedUpFolders[0],
            savedAt: Samples.pageMoment.addingTimeInterval(-200 * 86_400)),
          RestoredFolder(
            name: "Documents (20 Oct 2026)", path: documentsPath,
            source: Samples.backedUpFolders[0],
            savedAt: Samples.pageMoment.addingTimeInterval(-5 * 86_400)),
        ]), nil
    ),
    ("restore-drive-keeping", driveSheet(.keeping, restored: [restoredFolder]), nil),
    ("restore-drive-kept", driveSheet(.kept, restored: [restoredFolder]), nil),
    (
      "restore-drive-series-shared",
      driveSheet(
        .failed(RestoreProblem(BackupBuff.Failure.seriesShared("docs"), while: .backup)),
        restored: [restoredFolder]), nil
    ),
    (
      "restore-drive-empty",
      driveSheet(
        .failed(RestoreProblem(BackupBuff.Failure.backupIsEmpty, while: .backup)),
        restored: [restoredFolder]), nil
    ),
    (
      "restore-drive-offline",
      driveSheet(.failed(RestoreProblem(DriveProblem.unreachable, while: .backup)), mac: nil), nil
    ),
    (
      "restore-drive-other-account",
      driveSheet(
        .failed(
          RestoreProblem(BackupBuff.Failure.accountProblem(.otherAccount), while: .backup)),
        mac: nil), nil
    ),
    (
      "restore-drive-signed-out",
      driveSheet(.failed(RestoreProblem(DriveProblem.signedOut, while: .backup)), mac: nil), nil
    ),

    // The menu-bar popover while it runs, and Settings › Backup.
    (
      "restore-popover",
      AnyView(MenuBarView(state: Samples.restorePopover(restoring))), nil
    ),
    (
      "restore-settings-signed-in",
      AnyView(
        SettingsView(
          state: {
            var state = Samples.settings(.licensed)
            state.backup = BackupAccountSettings(isSignedIn: true, account: Samples.backupAccount)
            return state
          }())), nil
    ),
    (
      "restore-settings-signed-out",
      AnyView(
        SettingsView(
          state: {
            var state = Samples.settings(.licensed)
            state.backup = BackupAccountSettings(isSignedIn: false)
            return state
          }())), nil
    ),
  ]

  // The sheets open loading, so their natural size is the loading one: each is drawn at the size
  // of the step it is given.
  let sheetSizes: [String: CGSize] = [
    "restore-drive-empty": CGSize(width: 480, height: 148),
    "restore-drive-folders": CGSize(width: 540, height: 331),
    "restore-drive-folders-loading": CGSize(width: 480, height: 137),
    "restore-drive-keeping": CGSize(width: 480, height: 117),
    "restore-drive-kept": CGSize(width: 480, height: 132),
    "restore-drive-loading": CGSize(width: 480, height: 166),
    "restore-drive-macs": CGSize(width: 480, height: 194),
    "restore-drive-no-backups": CGSize(width: 480, height: 148),
    "restore-drive-offline": CGSize(width: 480, height: 132),
    "restore-drive-other-account": CGSize(width: 480, height: 164),
    "restore-drive-password": CGSize(width: 480, height: 188),
    "restore-drive-password-wrong": CGSize(width: 480, height: 210),
    "restore-drive-restored": CGSize(width: 540, height: 370),
    "restore-drive-restored-this-mac": CGSize(width: 540, height: 262),
    "restore-drive-restored-twice": CGSize(width: 540, height: 452),
    "restore-drive-restoring": CGSize(width: 480, height: 197),
    "restore-drive-series-shared": CGSize(width: 480, height: 164),
    "restore-drive-signed-out": CGSize(width: 480, height: 132),
    "restore-folder-cannot-write": CGSize(width: 480, height: 132),
    "restore-folder-choose": CGSize(width: 480, height: 306),
    "restore-folder-done": CGSize(width: 480, height: 120),
    "restore-folder-loading": CGSize(width: 480, height: 137),
    "restore-folder-no-room": CGSize(width: 480, height: 148),
    "restore-folder-password": CGSize(width: 480, height: 188),
    "restore-folder-password-wrong": CGSize(width: 480, height: 210),
    "restore-folder-restoring": CGSize(width: 480, height: 197),
    "restore-folder-starting": CGSize(width: 480, height: 197),
  ]
  return previews.map { preview in
    sheetSizes[preview.name].map { (preview.name, preview.view, $0) } ?? preview
  }

  /// The Backup card on Documents, with Show Versions… beside Take Off.
  func pageWithCard() -> AnyView {
    let shelf = Samples.backupShelf(Samples.backupLiveShelf)
    return AnyView(
      MainView(
        state: shelf,
        navigation: .constant(MainNavigation(.folder(1))),
        folderPage: { id in
          guard
            let state = FolderPageState(
              folderID: id, reports: Samples.backupLiveShelf, shelf: shelf,
              googleAccount: Samples.backupAccount, backupAttempts: Samples.backupAttempts,
              now: Samples.pageMoment, calendar: Samples.pageCalendar, binName: Samples.binName,
              home: Samples.pageHome)
          else { return AnyView(EmptyView()) }
          return AnyView(FolderPage(state: state, binName: Samples.binName))
        }))
  }
}

extension Samples {
  static let oldMac = BackedUpMac(id: "old", name: "Mei’s MacBook Pro", isThisMac: false)
  static let thisMac = BackedUpMac(id: "this", name: "Mei’s Mac mini", isThisMac: true)

  /// The 100 or so seconds restic has got through a 48 GB restore.
  static var restoreProgress: RestoreProgress {
    decode(
      #"{"percent_done":0.42,"seconds_elapsed":310,"total_files":8421,"files_restored":3540,"total_bytes":48000000000,"bytes_restored":20200000000}"#
    )
  }

  /// A snapshot as restic lists it, `ago` seconds before `pageMoment`.
  static func snapshot(_ id: String, ago: TimeInterval, bytes: Int64) -> ResticSnapshot {
    let time = ISO8601DateFormatter().string(from: pageMoment.addingTimeInterval(-ago))
    let json =
      #"{"id":"\#(id)","short_id":"\#(id.prefix(8))","time":"\#(time)","hostname":"mac-a","paths":["\#(home)/Documents"],"tags":["folder=docs"],"summary":{"total_bytes_processed":\#(bytes)}}"#
    return decode(json)
  }

  private static func decode<Value: Decodable>(_ json: String) -> Value {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    do {
      return try decoder.decode(Value.self, from: Data(json.utf8))
    } catch {
      fail("A preview's JSON didn't decode: \(error)")
    }
  }

  static var restoreSnapshots: [ResticSnapshot] {
    [
      snapshot("a1000001", ago: 12 * 60, bytes: 48_000_000_000),
      snapshot("a1000002", ago: 5 * 3_600, bytes: 47_900_000_000),
      snapshot("a1000003", ago: 5 * 86_400, bytes: 47_200_000_000),
      snapshot("a1000004", ago: 24 * 86_400, bytes: 45_600_000_000),
      snapshot("a1000005", ago: 200 * 86_400, bytes: 39_800_000_000),
    ].reversed()
  }

  static var restoreDates: [RestoreDate] {
    RestoreDate.list(restoreSnapshots, now: pageMoment, calendar: pageCalendar)
  }

  static var backedUpFolders: [BackedUpFolder] {
    [
      BackedUpFolder(
        series: "docs", name: "Documents", path: "\(home)/Documents", snapshots: restoreSnapshots),
      BackedUpFolder(
        series: "pics", name: "Pictures", path: "\(home)/Pictures",
        snapshots: Array(restoreSnapshots.suffix(3))),
      BackedUpFolder(
        series: "proj", name: "Projects", path: "\(home)/Projects",
        snapshots: Array(restoreSnapshots.suffix(1))),
    ]
  }

  /// A file's versions and a few more, as the Documents folder's Versions page lists them: each
  /// file's earliest version is the content from before its first recorded change (`replacedAt`),
  /// except where no backup from before it is kept.
  static var versions: VersionsState {
    let day: TimeInterval = 86_400
    func version(
      _ path: String, _ ago: TimeInterval, _ change: BackupVersion.Change, _ size: Int64?,
      before changeAgo: TimeInterval? = nil
    ) -> BackupVersion {
      BackupVersion(
        path: path, snapshotID: "s\(Int(ago))", savedAt: pageMoment.addingTimeInterval(-ago),
        change: change, size: size,
        replacedAt: changeAgo.map { pageMoment.addingTimeInterval(-$0) })
    }
    func history(_ path: String, _ versions: [BackupVersion], isMissing: Bool = false)
      -> FileHistory
    {
      FileHistory(
        path: path, versions: versions.sorted { $0.savedAt < $1.savedAt },
        hasEarlierVersionNotKept: isMissing)
    }
    return VersionsState(
      folderID: 1, folderName: "Documents", folderPath: "\(pageHome)/Documents",
      histories: [
        history(
          "Lease-2026.pdf",
          [
            version("Lease-2026.pdf", 4 * 3_600 + 1_500, .changed, 1_400_000),
            version("Lease-2026.pdf", 4 * day + 18 * 3_600 + 3_420, .changed, 1_400_000),
            version("Lease-2026.pdf", 20 * day + 9_300, .changed, 1_200_000),
            version(
              "Lease-2026.pdf", 20 * day + 62_520, .changed, nil, before: 20 * day + 9_300),
          ]),
        history(
          "Mei-CV-2026.pages",
          [
            version("Mei-CV-2026.pages", 7 * day, .changed, 2_800_000),
            version("Mei-CV-2026.pages", 12 * day, .changed, 2_700_000),
            version("Mei-CV-2026.pages", 19 * day, .changed, 2_700_000),
            version("Mei-CV-2026.pages", 30 * day, .changed, nil, before: 19 * day),
          ]),
        history(
          "Tax return 2025–26.pdf",
          [version("Tax return 2025–26.pdf", 23 * day, .changed, 640_000)], isMissing: true),
        history(
          "Wedding speech.docx",
          [
            version("Wedding speech.docx", 5 * 3_600, .changed, 88_000),
            version("Wedding speech.docx", day, .changed, 80_000),
            version("Wedding speech.docx", 3 * day, .changed, 62_000),
            version("Wedding speech.docx", 6 * day, .changed, nil, before: 3 * day),
          ]),
        history(
          "Finance/Receipts.xlsx",
          [
            version("Finance/Receipts.xlsx", 2 * day, .changed, 310_000),
            version("Finance/Receipts.xlsx", 9 * day, .added, 290_000),
          ]),
        history(
          "Old budget.numbers",
          [
            version("Old budget.numbers", 4 * day, .removed, nil),
            version("Old budget.numbers", 30 * day, .changed, 1_900_000),
            version("Old budget.numbers", 90 * day, .added, 1_700_000),
          ]),
        history(
          "Draft chapter 3.docx",
          [
            version("Draft chapter 3.docx", 11 * day, .removed, nil),
            version("Draft chapter 3.docx", 15 * day, .changed, nil, before: 11 * day),
          ]),
      ], now: pageMoment, calendar: pageCalendar)
  }

  /// The popover while a folder is being brought back.
  static func restorePopover(_ run: RestoreRun) -> PopoverState {
    PopoverState(
      folders: FolderState.all(
        backupLiveShelf, licence: .licensed, now: pageMoment, calendar: pageCalendar,
        binName: binName, home: pageHome),
      scheduleLines: scheduleLines(backupLiveShelf, now: pageMoment, calendar: pageCalendar),
      restore: run, licence: .licensed, now: pageMoment, calendar: pageCalendar)
  }
}

/// Restore Folder's sheet, opened loading and then given its step, with a pick going back into
/// the state as the app keeps it.
private struct FolderSheetArriving: View {
  var step: RestoreFolderState.Step
  var folderPath: String
  var password: String
  @State private var state: RestoreFolderState

  init(step: RestoreFolderState.Step, folderPath: String, password: String) {
    self.step = step
    self.folderPath = folderPath
    self.password = password
    _state = State(
      initialValue: RestoreFolderState(
        folderName: "Documents", folderPath: folderPath,
        step: ProcessInfo.processInfo.environment["PREVIEW_DIRECT"] == nil ? .loading : step))
  }

  var body: some View {
    RestoreFolderSheet(
      state: state, password: password, onSelectDate: { state.pickedDateID = $0 }
    )
    .onAppear { state.step = step }
  }
}

/// Restore from Google Drive's sheet, opened loading and then given its step.
private struct DriveSheetArriving: View {
  var step: RestoreFromDriveState.Step
  var mac: BackedUpMac?
  var restored: [RestoredFolder]
  var password: String
  @State private var state = RestoreFromDriveState(
    account: Samples.backupAccount, step: .loadingMacs)

  init(
    step: RestoreFromDriveState.Step, mac: BackedUpMac?, restored: [RestoredFolder],
    password: String
  ) {
    self.step = step
    self.mac = mac
    self.restored = restored
    self.password = password
    if ProcessInfo.processInfo.environment["PREVIEW_DIRECT"] != nil {
      _state = State(
        initialValue: RestoreFromDriveState(
          account: Samples.backupAccount, mac: mac, restored: restored, step: step))
    }
  }

  var body: some View {
    RestoreFromDriveSheet(
      state: state, now: Samples.pageMoment, calendar: Samples.pageCalendar, home: Samples.home,
      password: password, onSelectMac: { state.pickedMacID = $0 }
    )
    .onAppear {
      state.mac = mac
      state.restored = restored
      state.step = step
    }
  }
}
