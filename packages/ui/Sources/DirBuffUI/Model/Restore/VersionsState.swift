import DirBuffKit
import Foundation

/// Show Versions…: the files of a Backup folder that have a past, from the database alone (so it
/// lists offline), each with its versions: what the backup saved after each change, and the
/// content from before the first of them, which the snapshot before it holds. A file that hasn't
/// changed since the folder's first backup has the one version and isn't listed: Restore Folder
/// brings it back.
public struct VersionsState: Sendable, Equatable {
  /// The page's two lists: files still in the folder as the last backup saw it, and files the
  /// last backup found gone.
  public enum Tab: Sendable, Equatable, CaseIterable {
    case onThisMac
    case deleted

    public var title: String {
      switch self {
      case .onThisMac: "On This Mac"
      case .deleted: "Deleted"
      }
    }
  }

  public var folderID: Int64
  public var folderName: String
  public var folderPath: String
  /// Every file with versions, the one changed last first.
  public var files: [VersionedFile]

  public init(
    folderID: Int64, folderName: String, folderPath: String, histories: [FileHistory],
    now: Date, calendar: Calendar = .current
  ) {
    self.folderID = folderID
    self.folderName = folderName
    self.folderPath = folderPath
    files =
      histories
      .map { VersionedFile($0, now: now, calendar: calendar) }
      .sorted { ($0.latestAt, $0.path) > ($1.latestAt, $1.path) }
  }

  /// The files in `tab` whose name or folder has `query` in it.
  public func files(_ tab: Tab, matching query: String) -> [VersionedFile] {
    files.filter {
      ($0.isDeleted ? Tab.deleted : .onThisMac) == tab
        && (query.isEmpty || $0.path.localizedStandardContains(query))
    }
  }

  public func count(_ tab: Tab) -> Int { files(tab, matching: "").count }

  /// Under the page's title: "Backup · 14 files with versions".
  public var subtitle: String {
    files.isEmpty
      ? "Backup · no file has changed yet"
      : "Backup · \(files.count == 1 ? "1 file" : "\(files.count.formatted()) files") with versions"
  }

  /// What a tab says when it has nothing to list (or nothing matches the search).
  public func emptiness(_ tab: Tab, query: String) -> (title: String, detail: String) {
    if !query.isEmpty {
      return ("No matches", "No file here has “\(query)” in its name.")
    }
    if files.isEmpty {
      return (
        "No file has changed since the first backup",
        "Once a file in \(folderName) changes, its earlier versions are listed here, each restorable as a copy. A file that hasn't changed has the one version, and Restore Folder brings it back."
      )
    }
    switch tab {
    case .onThisMac:
      return ("Every file with versions has been deleted", "They are in the Deleted list.")
    case .deleted:
      return (
        "No file has been deleted",
        "A file deleted from \(folderName) is listed here, and each version of it can be restored."
      )
    }
  }
}

/// One file and its versions, the newest first.
public struct VersionedFile: Sendable, Equatable, Identifiable {
  /// Inside the folder.
  public var path: String
  public var name: String
  /// The folders it is in, inside the backed-up folder; empty at its top.
  public var parent: String
  public var versions: [FileVersion]
  /// The file existed before its first change, and no backup from before it is kept: the page
  /// says so rather than leave the gap unexplained.
  public var hasEarlierVersionNotKept: Bool

  /// What the inspector says under the versions when the earliest isn't there.
  public static let earlierNotKept =
    "No earlier version is kept: older backups thin out with age, and none from before the first change is left."

  public var id: String { path }

  /// Whether the last backup found it gone.
  public var isDeleted: Bool { versions.first?.change == .removed }

  /// When its newest version was saved.
  var latestAt: Date { versions.first?.savedAt ?? .distantPast }

  /// "Changed" in the list: when its newest version was saved.
  public var changed: String { versions.first?.when ?? "" }

  /// "1.4 MB", its newest version's; "—" for a deleted file.
  public var size: String { versions.first(where: { $0.size != nil })?.size ?? "—" }

  /// The versions that hold a file to restore: a deletion holds none.
  public var restorableCount: Int { versions.filter(\.canRestore).count }

  /// "4 versions" over the file's name in the inspector.
  public var versionCount: String {
    restorableCount == 1 ? "1 version" : "\(restorableCount) versions"
  }

  init(_ history: FileHistory, now: Date, calendar: Calendar) {
    path = history.path
    hasEarlierVersionNotKept = history.hasEarlierVersionNotKept
    let parts = path.split(separator: "/")
    name = parts.last.map(String.init) ?? path
    parent = parts.dropLast().joined(separator: "/")
    let sorted = history.versions.sorted { $0.savedAt > $1.savedAt }
    self.versions = sorted.enumerated().map { index, version in
      FileVersion(version, isLatest: index == 0, now: now, calendar: calendar)
    }
  }
}

/// One saved state of a file, as the inspector lists it.
public struct FileVersion: Sendable, Equatable, Identifiable {
  public var version: BackupVersion
  /// "Today, 09:12", "Tue 20 Oct, 18:40", "20 Oct 2025, 18:40".
  public var when: String
  /// What it was: "Latest backup · 1.4 MB", "Changed · 1.2 MB", "Deleted".
  public var detail: String
  /// Its size alone, "1.4 MB"; nil for a deletion.
  public var size: String?

  public var id: String { version.snapshotID + version.path }
  public var change: BackupVersion.Change { version.change }
  public var savedAt: Date { version.savedAt }

  /// A deletion is no version of the file: there is nothing of it to restore.
  public var canRestore: Bool { version.change != .removed }

  init(_ version: BackupVersion, isLatest: Bool, now: Date, calendar: Calendar) {
    self.version = version
    when = versionMoment(version.savedAt, now: now, calendar: calendar)
    size = version.size.map(bytes)
    let sizeWords = size.map { " · \($0)" } ?? ""
    detail =
      if let replacedAt = version.replacedAt {
        "As backed up before \(versionDay(replacedAt, now: now, calendar: calendar))"
      } else {
        switch version.change {
        case .removed: "Deleted"
        case .added: "\(isLatest ? "Latest backup" : "Added")\(sizeWords)"
        case .changed: "\(isLatest ? "Latest backup" : "Changed")\(sizeWords)"
        }
      }
  }
}

/// When a version was saved, told as the Versions page does: "Today, 09:12", "Tue 20 Oct, 18:40",
/// and with the year once it isn't this year's.
func versionMoment(_ date: Date, now: Date, calendar: Calendar) -> String {
  let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
  let time = date.formatted(style.hour().minute())
  if daysAhead(date, now: now, calendar: calendar) == 0 { return "Today, \(time)" }
  let isThisYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
  let day =
    isThisYear
    ? date.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
    : date.formatted(style.day().month(.abbreviated).year())
  return "\(day), \(time)"
}

/// The day a change was made, for "As backed up before 6 Nov": with the year once it isn't this
/// year's.
func versionDay(_ date: Date, now: Date, calendar: Calendar) -> String {
  let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
  let isThisYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
  return isThisYear
    ? date.formatted(style.day().month(.abbreviated))
    : date.formatted(style.day().month(.abbreviated).year())
}
