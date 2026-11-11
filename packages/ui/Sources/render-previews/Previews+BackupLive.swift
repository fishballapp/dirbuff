import DirBuffCore
import DirBuffKit
import DirBuffUI
import SwiftUI

/// Backup as a wearable buff: the Buffs page, the Google sign-in sheet in each step, the card with
/// its account, history pop-up, what it leaves out and its latest backups, Show Files, Settings ›
/// Backup and the password sheet, and Finder's menus.
@MainActor
func backupLivePreviews() -> [Preview] {
  let full = CGSize(width: 1240, height: 800)
  let tall = CGSize(width: 1240, height: 900)
  let account = Samples.backupAccount
  let documentsPath = "\(Samples.pageHome)/Documents"

  /// The window at a folder's page, with the account and its latest backups.
  func page(
    _ reports: [FolderReport], folder: Int64, account: String? = account,
    attempts: [BackupAttempt] = Samples.backupAttempts, toast: SettingsToast? = nil,
    home: String = Samples.pageHome
  ) -> AnyView {
    let shelf = MainState(
      reports: reports, licence: .licensed, now: Samples.pageMoment,
      calendar: Samples.pageCalendar, binName: Samples.binName, home: home,
      startupVolumeName: "Macintosh HD")
    return AnyView(
      MainView(
        state: shelf,
        navigation: .constant(MainNavigation(.folder(folder))),
        folderPage: { id in
          guard
            let state = FolderPageState(
              folderID: id, reports: reports, shelf: shelf, googleAccount: account,
              backupAttempts: attempts, now: Samples.pageMoment, calendar: Samples.pageCalendar,
              binName: Samples.binName, home: home)
          else { return AnyView(EmptyView()) }
          return AnyView(FolderPage(state: state, binName: Samples.binName, toast: toast))
        }))
  }

  func signIn(_ reason: GoogleSignInState.Reason, _ step: GoogleSignInState.Step) -> AnyView {
    AnyView(GoogleSignInSheet(state: GoogleSignInState(reason: reason, step: step)))
  }
  let documents = GoogleSignInState.Reason.backUp(
    folderName: "Documents", folderPath: documentsPath)

  let unread = UnreadFilesState(Samples.backupOwnStates[3])
  func filesWindow(_ state: UnreadFilesState?) -> AnyView {
    AnyView(
      MainView(
        state: Samples.backupShelf(Samples.backupOwnStates),
        navigation: .constant(MainNavigation(opening: .unreadFiles(4))),
        page: { _ in
          AnyView(
            UnreadFilesPage(
              state: state, folderName: "Projects",
              folderPath: "\(Samples.pageHome)/Projects"))
        }))
  }

  func settings(_ backup: BackupAccountSettings) -> AnyView {
    var state = Samples.settings(.licensed)
    state.backup = backup
    return AnyView(SettingsView(state: state))
  }

  return [
    // Backup leaves Soon.
    (
      "live-buffs-page",
      AnyView(
        MainView(
          state: Samples.backupShelf(Samples.backupLiveShelf),
          navigation: .constant(MainNavigation(.buffs)))), full
    ),
    (
      "live-shelf",
      AnyView(
        MainView(
          state: Samples.backupShelf(Samples.backupLiveShelf),
          navigation: .constant(MainNavigation(.allFolders)))), full
    ),

    // The sign-in sheet, each step.
    ("live-sign-in-ask", signIn(documents, .ask), nil),
    ("live-sign-in-waiting", signIn(documents, .waiting), nil),
    ("live-sign-in-account", signIn(documents, .signedIn(account: account)), nil),
    (
      "live-sign-in-failed",
      signIn(
        documents,
        .failed("Google said DirBuff may not use your Drive. Try again and choose Allow.")),
      nil
    ),
    ("live-sign-in-again", signIn(.signInAgain, .ask), nil),
    ("live-sign-in-again-account", signIn(.signInAgain, .signedIn(account: account)), nil),
    ("live-sign-in-settings", signIn(.settings, .ask), nil),
    ("live-sign-in-settings-account", signIn(.settings, .signedIn(account: account)), nil),

    // The card.
    ("live-card-documents", page(Samples.backupLiveShelf, folder: 1), tall),
    // The fixtures' made-up home, so no real user name is drawn.
    ("live-card-home", page(Samples.backupLiveShelf, folder: 2, home: Samples.home), tall),
    ("live-card-pictures", page(Samples.backupLiveShelf, folder: 3), tall),
    ("live-card-both", page(Samples.backupLiveShelf, folder: 4), tall),
    (
      "live-card-waiting", page(Samples.backupLiveWaiting, folder: 1, account: nil, attempts: []),
      full
    ),
    ("live-card-failing", page(Samples.backupLiveFailing, folder: 1), tall),
    ("live-card-files", page(Samples.backupLiveUnread, folder: 1), tall),
    ("live-card-part-missing", page(Samples.backupLivePartMissing, folder: 1), tall),
    (
      "live-card-toast",
      page(
        Samples.backupLiveShortHistory, folder: 1,
        toast: SettingsToast(
          change: settingChange(from: BackupSettings(), to: BackupSettings(history: .oneYear)),
          previous: .backup(BackupSettings()))), tall
    ),

    ("live-card-left-out", page(Samples.backupLiveLeftOut, folder: 1), tall),
    alertPreview("live-alert-start-again", .startAgain),
    alertPreview("live-alert-take-off", .takeOff(folderName: "Documents")),

    // Round 3: another account, asking first, Undo, the password finishing, the drop card.
    (
      "live-sign-in-other-account",
      signIn(
        .signInAgain, .otherAccount(owner: "mei.chan@gmail.com", signedIn: "mei@work.example")),
      nil
    ),
    (
      "live-card-other-account",
      page(
        [
          Samples.backupReport(
            id: 1, "Documents", drive: .otherAccount(owner: "mei.chan@gmail.com"))
        ],
        folder: 1), tall
    ),
    alertPreview(
      "live-alert-start-new-backup",
      .startNewBackup(owner: "mei.chan@gmail.com", signedIn: "mei@work.example")),
    alertPreview("live-alert-add-backup", .addBackup(folderName: "Documents")),
    alertPreview("live-alert-undo-shorter", .shorterHistory(.thirtyDays, folderName: "Documents")),
    (
      "live-password-finishing",
      AnyView(BackupPasswordSheet(state: BackupPasswordSheetState(mode: .set, isFinishing: true))),
      nil
    ),
    (
      "live-drop-card-backup",
      AnyView(
        AddedBackupCard(
          folderName: "Documents", folderPath: documentsPath, account: account, onUndo: {},
          onDone: {}
        ).background(.background)), nil
    ),
    (
      "live-welcome-pieces",
      AnyView(
        HStack(spacing: 10) {
          ForEach(Buff.allCases, id: \.self) { buff in
            BuffPiece(buff, isDraggable: buff != .backup).fixedSize()
          }
        }.padding(20)), nil
    ),

    // Show Files.
    ("live-show-files", filesWindow(unread), full),
    ("live-show-files-empty", filesWindow(nil), full),

    // Settings › Backup.
    ("live-settings-signed-out", settings(BackupAccountSettings(isSignedIn: false)), nil),
    (
      "live-settings-signed-in",
      settings(BackupAccountSettings(isSignedIn: true, account: account)), nil
    ),
    (
      "live-settings-password",
      settings(
        BackupAccountSettings(isSignedIn: true, account: account, isPasswordProtected: true)), nil
    ),

    // The password sheet.
    (
      "live-password-set",
      AnyView(BackupPasswordSheet(state: BackupPasswordSheetState(mode: .set))), nil
    ),
    (
      "live-password-mismatch",
      AnyView(
        BackupPasswordSheet(
          state: BackupPasswordSheetState(mode: .set), password: "orange kettle runway",
          confirmation: "orange kettle")), nil
    ),
    (
      "live-password-short",
      AnyView(
        BackupPasswordSheet(
          state: BackupPasswordSheetState(mode: .set), password: "orange", confirmation: "")),
      nil
    ),
    (
      "live-password-saving",
      AnyView(
        BackupPasswordSheet(
          state: BackupPasswordSheetState(mode: .change, isSaving: true),
          password: "orange kettle runway", confirmation: "orange kettle runway")), nil
    ),
    (
      "live-password-failed",
      AnyView(
        BackupPasswordSheet(
          state: BackupPasswordSheetState(
            mode: .change,
            failure: "Google Drive can't be reached. Try again once you're online."),
          password: "orange kettle runway", confirmation: "orange kettle runway")), nil
    ),

    // Finder.
    (
      "live-finder-add",
      AnyView(
        FinderMenuSheet(
          menu: FinderMenu.addBuff(
            folderName: "Documents", isProtected: false, binName: Samples.binName))), nil
    ),
    (
      "live-finder-backup",
      AnyView(
        FinderMenuSheet(
          menu: Samples.backupFinderMenu(
            [Samples.backupReport(id: 1, "Documents")], folder: "Documents"))),
      nil
    ),
    (
      "live-finder-home",
      AnyView(
        FinderMenuSheet(
          menu: FinderMenu.buffs(
            folderName: "mei",
            worn: [
              FinderBuff(
                buff: .backup, setting: "Every version, thinning with age",
                nextEvent: "Backed up 12 min ago")
            ],
            isProtected: true, binName: Samples.binName))), nil
    ),
  ]
}

extension Samples {
  /// A made-up account, as the design reference uses.
  static let backupAccount = "mei.chan@gmail.com"

  /// The latest backups the card lists, newest first.
  static var backupAttempts: [BackupAttempt] {
    func attempt(
      _ ago: TimeInterval, new: Int = 0, changed: Int = 0, bytes: Int64 = 0, skipped: Int = 0,
      error: String? = nil
    ) -> BackupAttempt {
      let start = pageMoment.addingTimeInterval(-ago)
      return BackupAttempt(
        startedAt: start, endedAt: start.addingTimeInterval(40),
        snapshotID: error == nil ? "a1b2c3" : nil, filesNew: new, filesChanged: changed,
        bytesAdded: bytes, skippedCount: skipped, error: error)
    }
    return [
      attempt(12 * 60, new: 3, changed: 14, bytes: 48_000_000),
      attempt(75 * 60, changed: 2, bytes: 1_200_000),
      attempt(5 * 3_600, error: "The connection to Google Drive was lost"),
      attempt(26 * 3_600, new: 41, changed: 6, bytes: 820_000_000, skipped: 2),
      attempt(3 * 86_400),
    ]
  }

  /// Documents, Home and Pictures wearing Backup, and Downloads wearing both.
  static var backupLiveShelf: [FolderReport] {
    [
      backupReport(id: 1, "Documents"),
      backupReport(id: 2, "sample", path: home),
      backupReport(id: 3, "Pictures", status: backupStatus(lastSuccess: 5 * 60, cloudOnly: 120)),
      backupReport(
        id: 4, "Downloads",
        status: BackupStatus(
          lastRunAt: pageMoment, lastSuccessAt: pageMoment.addingTimeInterval(-40 * 60),
          leftOut: [.path("Installers"), .name("build")]),
        temporary: TemporarySettings(maxAgeDays: 14)),
    ]
  }

  static var backupLiveWaiting: [FolderReport] {
    [backupReport(id: 1, "Documents", status: nil, drive: .notSignedIn)]
  }

  static var backupLiveFailing: [FolderReport] {
    [backupReport(id: 1, "Documents", status: failingStatus)]
  }

  static var backupLiveUnread: [FolderReport] {
    [backupReport(id: 1, "Documents", status: backupStatus(skipped: unreadableFiles))]
  }

  /// Documents with three things the user left out from Show Files.
  static var backupLiveLeftOut: [FolderReport] {
    [
      backupReport(
        id: 1, "Documents",
        status: BackupStatus(
          lastRunAt: pageMoment, lastSuccessAt: pageMoment.addingTimeInterval(-12 * 60),
          leftOut: [.path("Taxes/receipts.zip"), .path("Notes.sqlite"), .name("build")]))
    ]
  }

  static var backupLivePartMissing: [FolderReport] {
    [backupReport(id: 1, "Documents", drive: .partMissing)]
  }

  static var backupLiveShortHistory: [FolderReport] {
    var report = backupReport(id: 1, "Documents")
    report.buffs = report.buffs.map {
      guard case .backup(var wear, let reading) = $0 else { return $0 }
      wear.settings = BackupSettings(history: .oneYear)
      return .backup(wear, reading)
    }
    return [report]
  }
}

/// A system alert as the app runs it, at its own size.
@MainActor
private func alertPreview(_ name: String, _ alert: BackupAlert) -> Preview {
  (name, AnyView(AlertSnapshot(alert: alert)), AlertSnapshot.size(of: alert))
}

/// A system alert as the app runs it: the `NSAlert` laid out in its own window, in the preview's
/// appearance, and drawn from there.
struct AlertSnapshot: View {
  var alert: BackupAlert

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if let image = snapshot() {
      Image(nsImage: image)
    }
  }

  /// The alert's own size, so the preview draws nothing around it.
  @MainActor
  static func size(of alert: BackupAlert) -> CGSize? {
    let nsAlert = alert.makeAlert()
    nsAlert.window.appearance = NSAppearance(named: .aqua)
    nsAlert.layout()
    nsAlert.window.contentView?.layoutSubtreeIfNeeded()
    return nsAlert.window.contentView?.bounds.size
  }

  @MainActor
  private func snapshot() -> NSImage? {
    let nsAlert = alert.makeAlert()
    nsAlert.window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    nsAlert.layout()
    guard let content = nsAlert.window.contentView else { return nil }
    content.layoutSubtreeIfNeeded()
    guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
    content.cacheDisplay(in: content.bounds, to: rep)
    let image = NSImage(size: content.bounds.size)
    image.addRepresentation(rep)
    return image
  }
}
