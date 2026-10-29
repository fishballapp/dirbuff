import DirBuffCore
import DirBuffKit
import Foundation

/// The welcome window's live checklist: what the system has been told, each row its real state.
public struct SetupState: Sendable, Equatable {
  public var isExtensionEnabled: Bool
  public var isOpenAtLogin: Bool
  public var isOpenAtLoginRequiresApproval: Bool
  public var isNotificationsEnabled: Bool

  public init(
    isExtensionEnabled: Bool = false,
    isOpenAtLogin: Bool = false,
    isOpenAtLoginRequiresApproval: Bool = false,
    isNotificationsEnabled: Bool = false
  ) {
    self.isExtensionEnabled = isExtensionEnabled
    self.isOpenAtLogin = isOpenAtLogin
    self.isOpenAtLoginRequiresApproval = isOpenAtLoginRequiresApproval
    self.isNotificationsEnabled = isNotificationsEnabled
  }
}

/// A folder tile in the welcome window, where a buff piece can be dropped.
public struct WelcomeFolder: Sendable, Equatable, Identifiable {
  public var id: String { path }
  public var name: String
  public var path: String

  public init(name: String, path: String) {
    self.name = name
    self.path = path
  }
}

/// Temporary on a folder, as the app has it now: what the tile and the sentence under the tiles
/// say about it.
public struct WelcomePlacement: Sendable, Equatable {
  public var folder: WelcomeFolder
  /// The folder's id in the registry, which Undo and Change… name.
  public var folderID: Int64
  /// The tile's line next to the symbol: "90 days".
  public var setting: String
  /// What it means, in numbers: "Files older than 90 days are moved to the Bin; 3 to clear tomorrow."
  public var sentence: String

  public init(folder: WelcomeFolder, folderID: Int64, setting: String, sentence: String) {
    self.folder = folder
    self.folderID = folderID
    self.setting = setting
    self.sentence = sentence
  }

  /// `status` is the folder as the engine last read it; without it the sentence says only what
  /// the setting does.
  public init(
    folder: WelcomeFolder,
    folderID: Int64,
    settings: TemporarySettings,
    status: Engine.FolderStatus?,
    now: Date,
    calendar: Calendar = .current,
    binName: String = SystemBin.name
  ) {
    let disposal =
      settings.disposal == .delete ? "are deleted permanently" : "are moved to the \(binName)"
    let (setting, promise) =
      switch settings.rule {
      case .age:
        (days(settings.maxAgeDays), "Files older than \(days(settings.maxAgeDays)) \(disposal)")
      case .size:
        (
          bytes(settings.sizeLimit),
          "The oldest files \(disposal) once the folder passes \(bytes(settings.sizeLimit))"
        )
      case .automatic:
        ("Automatic", "The oldest files are deleted when the disk is nearly full")
      case .emptyOnRestart:
        ("At restart", "Files \(disposal) at restart")
      }
    self.init(
      folder: folder, folderID: folderID, setting: setting,
      sentence:
        "\(promise)\(Self.next(status, settings: settings, now: now, calendar: calendar).map { "; \($0)" } ?? "")."
    )
  }

  /// "3 to clear in 23 min" (the soonest clean-up's), "38 to clear at restart", or "nothing to
  /// clear yet"; nil when the folder couldn't be read.
  private static func next(
    _ status: Engine.FolderStatus?, settings: TemporarySettings, now: Date, calendar: Calendar
  ) -> String? {
    guard let status else { return nil }
    let cleanUps = status.cleanUps(now: now, calendar: calendar)
    guard let soonest = cleanUps.first?.at else {
      let atRestart = status.clearedAtRestart(settings).count
      return atRestart > 0 ? "\(atRestart) to clear at restart" : "nothing to clear yet"
    }
    let together = soonestTogether(cleanUps, now: now, calendar: calendar).count
    return "\(together) to clear \(cleanUpFromNow(soonest, now: now, calendar: calendar))"
  }
}

/// Everything the welcome window shows: the checklist, the folder tiles, and the licence's line at
/// the foot. What wears Temporary is read from `reports`, the folders as the app has them now, so
/// a tile follows a change made on the folder's page or anywhere else.
public struct WelcomeState: Sendable {
  public var setup: SetupState
  public var licence: Licence
  /// The usual folders, before "Other Folder…".
  public var folders: [WelcomeFolder]
  public var reports: [FolderReport]
  /// The folder the user chose last in this window, which the sentence under the tiles is about.
  public var chosen: WelcomeFolder?
  /// A folder the user picked with "Other Folder…" in this window.
  public var otherFolder: WelcomeFolder?
  /// The folders this window put Temporary on, which Undo may take off again. One that already
  /// wore it is shown as done and left alone.
  public var addedHere: Set<WelcomeFolder.ID>
  /// Why the last try didn't go on, until the next one: the licence stopped it.
  public var refusal: String?
  public var now: Date
  public var calendar: Calendar
  public var binName: String

  public init(
    setup: SetupState,
    licence: Licence,
    folders: [WelcomeFolder],
    reports: [FolderReport] = [],
    chosen: WelcomeFolder? = nil,
    otherFolder: WelcomeFolder? = nil,
    addedHere: Set<WelcomeFolder.ID> = [],
    refusal: String? = nil,
    now: Date = Date(),
    calendar: Calendar = .current,
    binName: String = SystemBin.name
  ) {
    self.setup = setup
    self.licence = licence
    self.folders = folders
    self.reports = reports
    self.chosen = chosen
    self.otherFolder = otherFolder
    self.addedHere = addedHere
    self.refusal = refusal
    self.now = now
    self.calendar = calendar
    self.binName = binName
  }

  /// Temporary on `folder` as it is now, if the folder wears it.
  public func placement(on folder: WelcomeFolder) -> WelcomePlacement? {
    let path = (try? canonicalPath(of: URL(fileURLWithPath: folder.path))) ?? folder.path
    guard let report = reports.first(where: { $0.folder.path == path && $0.folder.wearsTemporary }),
      let id = report.folder.id
    else { return nil }
    return WelcomePlacement(
      folder: folder, folderID: id, settings: report.folder.settings, status: report.status,
      now: now, calendar: calendar, binName: binName)
  }

  /// What "Other Folder…" shows once a folder was picked and still wears Temporary.
  public var otherPlacement: WelcomePlacement? { otherFolder.flatMap(placement(on:)) }

  /// The placement the sentence under the tiles is about: the folder chosen last, while it wears
  /// Temporary.
  public var chosenPlacement: WelcomePlacement? { chosen.flatMap(placement(on:)) }

  /// Whether this window may take the buff off `placement`'s folder: only if it put it there.
  public func canUndo(_ placement: WelcomePlacement) -> Bool {
    addedHere.contains(placement.folder.id)
  }

  /// Whether a buff is on one of the tiles.
  public var isDone: Bool {
    (folders + [otherFolder].compactMap(\.self)).contains { placement(on: $0) != nil }
  }

  /// What the closing button is called: **Later** until a buff is on, then **Done**.
  public var closeTitle: String { isDone ? "Done" : "Later" }

  /// The usual folders of this Mac: Downloads, Desktop and Documents.
  public static func usualFolders(home: String = NSHomeDirectory()) -> [WelcomeFolder] {
    ["Downloads", "Desktop", "Documents"].map { WelcomeFolder(name: $0, path: "\(home)/\($0)") }
  }
}
