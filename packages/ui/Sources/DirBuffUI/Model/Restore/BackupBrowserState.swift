import DirBuffKit
import Foundation
import UniformTypeIdentifiers

/// The backup page (Browse Backup…): a Backup folder's backups, newest first; the folder as the one
/// chosen saved it, opened a folder at a time as Finder's column view opens one; and beside them
/// the item selected, with a file's timeline across the backups. Each folder is listed from Google
/// Drive when it is opened and kept until the page closes (a backup never changes); the backups
/// and the timelines come from the database, so they show offline.
public struct BackupBrowserState: Sendable, Equatable {
  /// Quick Look downloads a file to show it; past this size the sidebar says to restore it.
  public static let quickLookLimit: Int64 = 100_000_000

  public enum Backups: Sendable, Equatable {
    case loading
    /// Newest first.
    case loaded([KeptBackup])
    case failed(RestoreProblem)
  }

  /// One folder of one backup, as a column lists it.
  public enum Listing: Sendable, Equatable {
    case loading
    case loaded([BackupItem])
    case failed(RestoreProblem)
  }

  /// What a restore of one item has got to. It belongs to that item in that backup, whatever is
  /// selected meanwhile.
  public enum ItemRestore: Sendable, Equatable {
    case restoring(RestoreRun)
    /// Where it went.
    case done(path: String)
    case failed(RestoreProblem)
  }

  public var folderName: String
  public var folderPath: String
  public var backups: Backups
  /// The backup shown: the newest until the user picks another.
  public private(set) var backupID: String?
  /// The item selected, as the listing it was chosen in had it; nil for the backup itself, the
  /// folder as a whole.
  public private(set) var selection: BackupItem?
  public var listings: [BackupPlace: Listing] = [:]
  /// Files' histories by path, read from the database as they are selected.
  public var histories: [String: FileHistory] = [:]
  public var restores: [BackupPlace: ItemRestore] = [:]
  /// The file Quick Look is downloading.
  public var quickLooking: BackupPlace?
  /// Items being copied into Finder by a drag.
  public var dragsInFlight = 0
  /// What Backup's schedule is running with restic now. A listing, a restore, Quick Look or a
  /// drag runs after it, one restic command at a time, so the page says what it waits for.
  public var busyWith: BackupBusy?
  /// The backed-up folder isn't on this Mac now (deleted, in the Bin, on a disk that isn't
  /// connected): its backups browse as ever, but Restore asks where to put what it brings back.
  public var isFolderAway = false
  /// The backup's password is being asked for: this Mac's Keychain doesn't open it.
  public var passwordAsk: PasswordAsk?

  public init(folderName: String, folderPath: String, backups: Backups = .loading) {
    self.folderName = folderName
    self.folderPath = folderPath
    self.backups = .loading
    show(backups)
  }

  // MARK: Choosing

  /// The backups, once known. The one shown stays shown while it is still kept.
  public mutating func show(_ backups: Backups) {
    self.backups = backups
    guard case .loaded(let list) = backups else { return }
    if !list.contains(where: { $0.id == backupID }) {
      backupID = list.first?.id
      selection = nil
    }
  }

  /// A backup chosen in the first column: its top shows, as Finder starts a new column view.
  public mutating func selectBackup(_ id: String) {
    guard id != backupID else { return }
    backupID = id
    selection = nil
  }

  /// An item chosen in a column; nil chooses the backup itself.
  public mutating func select(_ item: BackupItem?) {
    selection = item
  }

  /// A timeline entry chosen: its backup shows, with the same file selected, its folders open.
  public mutating func show(_ entry: TimelineEntry) {
    guard entry.canShow, let file = selection else { return }
    backupID = entry.backupID
    selection = BackupItem(path: file.path, kind: file.kind)
  }

  /// The listing of `place` arrived. When it is on the way to the selection but hasn't the next
  /// folder or the file (that backup doesn't hold it), the selection stops at the folder.
  public mutating func didList(_ place: BackupPlace, _ items: [BackupItem]) {
    listings[place] = .loaded(items)
    guard place.backupID == backupID, let selection,
      let next = Self.step(from: place.path, toward: selection.path),
      !items.contains(where: { $0.path == next })
    else { return }
    self.selection = parentItem(of: place.path)
  }

  /// The folder at `path` as an item to select; nil at the top.
  private func parentItem(of path: String) -> BackupItem? {
    path.isEmpty ? nil : BackupItem(path: path, kind: .folder)
  }

  /// The path of the item inside `folder` on the way to `path`; nil when `path` isn't inside it.
  static func step(from folder: String, toward path: String) -> String? {
    let parts = path.split(separator: "/")
    let depth = folder.isEmpty ? 0 : folder.split(separator: "/").count
    guard parts.count > depth,
      folder.isEmpty || path.hasPrefix(folder + "/")
    else { return nil }
    return parts.prefix(depth + 1).joined(separator: "/")
  }

  // MARK: Keys

  /// Up and down in the column the selection is in, Right into a folder, Left out of one.
  public mutating func move(_ direction: Direction) {
    guard let backupID else { return }
    let folder = selection?.parent ?? ""
    let siblings = items(in: BackupPlace(backupID: backupID, path: folder)) ?? []
    switch direction {
    case .up, .down:
      guard let selection else {
        self.selection = siblings.first
        return
      }
      guard let index = siblings.firstIndex(where: { $0.path == selection.path }) else { return }
      let next = direction == .up ? index - 1 : index + 1
      if siblings.indices.contains(next) { self.selection = siblings[next] }
    case .right:
      guard let selection else {
        self.selection = siblings.first
        return
      }
      guard selection.isFolder,
        let first = items(in: BackupPlace(backupID: backupID, path: selection.path))?.first
      else { return }
      self.selection = first
    case .left:
      guard let selection else { return }
      self.selection = parentItem(of: selection.parent)
    }
  }

  public enum Direction: Sendable {
    case up, down, left, right
  }

  // MARK: What shows

  /// The backup shown.
  public var backup: KeptBackup? {
    guard case .loaded(let list) = backups else { return nil }
    return list.first { $0.id == backupID }
  }

  public var keptBackups: [KeptBackup] {
    guard case .loaded(let list) = backups else { return [] }
    return list
  }

  /// The folder columns, from the backup's top to the folder selected or the one holding the
  /// file selected.
  public var columns: [BackupColumn] {
    guard let backupID else { return [] }
    var folders = [""]
    if let selection {
      let parts = selection.path.split(separator: "/")
      for depth in parts.indices.dropLast() {
        folders.append(parts.prefix(depth + 1).joined(separator: "/"))
      }
      if selectedItem?.isFolder ?? selection.isFolder { folders.append(selection.path) }
    }
    // A column opens once the one before it is listed, as Finder's do: one still loading or
    // failed is the last.
    if let unlisted = folders.firstIndex(where: {
      items(in: BackupPlace(backupID: backupID, path: $0)) == nil
    }) {
      folders = Array(folders.prefix(through: unlisted))
    }
    let active = selection.map { folders.firstIndex(of: $0.parent) ?? 0 }
    return folders.enumerated().map { index, folder in
      let place = BackupPlace(backupID: backupID, path: folder)
      return BackupColumn(
        place: place, listing: listings[place] ?? .loading,
        selectedPath: selection.flatMap { Self.step(from: folder, toward: $0.path) },
        isActive: index == active)
    }
  }

  /// The folders opened whose listing hasn't been asked for.
  public var listingsWanted: [BackupPlace] {
    columns.map(\.place).filter { listings[$0] == nil }
  }

  /// The selection as the backup shown has it, marks and size included; nil until its folder is
  /// listed, or when that backup doesn't hold it.
  public var selectedItem: BackupItem? {
    guard let backupID, let selection else { return nil }
    return items(in: BackupPlace(backupID: backupID, path: selection.parent))?
      .first { $0.path == selection.path }
  }

  /// What's on this item's place in the backup shown: its restore, if one was started.
  public var selectedRestore: ItemRestore? {
    guard let place = selectedPlace else { return nil }
    return restores[place]
  }

  /// The paths of `backupID` being restored now, for the rows' spinners.
  public func restoringPaths(in backupID: String) -> Set<String> {
    Set(
      restores.compactMap { place, restore in
        guard place.backupID == backupID, case .restoring = restore else { return nil }
        return place.path
      })
  }

  /// The selection in the backup shown.
  public var selectedPlace: BackupPlace? {
    guard let backupID, let selection else { return nil }
    return BackupPlace(backupID: backupID, path: selection.path)
  }

  /// A listing's items, once it has arrived.
  public func items(in place: BackupPlace) -> [BackupItem]? {
    guard case .loaded(let items) = listings[place] else { return nil }
    return items
  }

  // MARK: The sidebar

  /// "PDF document", "Folder"; from the name's extension, as Finder says it.
  public static func kind(of item: BackupItem) -> String {
    switch item.kind {
    case .folder: return "Folder"
    case .link: return "Alias"
    case .file:
      let pathExtension = (item.name as NSString).pathExtension
      return UTType(filenameExtension: pathExtension)?.localizedDescription?.capitalizedFirst
        ?? "Document"
    }
  }

  /// Under the selection's name: "PDF document · 1.4 MB", "Folder · 12 items".
  public func facts(of item: BackupItem) -> String {
    var parts = [Self.kind(of: item)]
    if let size = item.size { parts.append(bytes(size)) }
    if item.isFolder, let backupID,
      let inside = items(in: BackupPlace(backupID: backupID, path: item.path))
    {
      parts.append(
        inside.isEmpty
          ? "Empty" : inside.count == 1 ? "1 item" : "\(inside.count.formatted()) items")
    }
    return parts.joined(separator: " · ")
  }

  /// What became of it since the backup shown, in a sentence; nil when it is as it was.
  public func sinceThen(of item: BackupItem) -> String? {
    switch item.sinceThen {
    case nil: nil
    case .deleted: "\(parentName(of: item)) on this Mac doesn't have it any more."
    case .changed:
      item.isFolder
        ? "Something in it has changed on this Mac since this backup."
        : "It has changed on this Mac since this backup."
    case .unknown:
      isFolderAway
        ? "\(folderName) isn't on this Mac now, so DirBuff can't tell what has changed since this backup."
        : "DirBuff can't read \(parentName(of: item)) on this Mac, so it can't tell what has changed since this backup."
    }
  }

  /// What Restore will do, under the button.
  public func restoreSentence(for item: BackupItem) -> String {
    if isFolderAway {
      return
        "\(folderName) isn't on this Mac now, so Restore To… asks where to put it. Nothing is replaced."
    }
    if item.sinceThen == .unknown {
      return
        "Restore puts it back in \(parentName(of: item)), under its own name if that's free and beside what has it if not. Nothing is replaced."
    }
    guard item.sinceThen != .deleted, let backup else {
      return "Restore puts it back in \(parentName(of: item)), as this backup saved it."
    }
    return
      "Restore puts it in \(parentName(of: item)) beside the one there now, as “\(BackupBuff.datedName(of: item, savedAt: backup.savedAt))”. Nothing is replaced."
  }

  /// What Restore Folder does with the backup as a whole.
  public var restoreFolderSentence: String {
    guard let backup else { return "" }
    let name =
      folderName + " (" + backup.savedAt.formatted(date: .abbreviated, time: .omitted) + ")"
    if isFolderAway {
      return
        "\(folderName) isn't on this Mac now, so Restore Folder… asks where to put it, as “\(name)”."
    }
    return
      "It comes back as a new folder beside \(folderName), “\(name)”. Nothing in \(folderName) is replaced."
  }

  /// Restore's button: it asks where when the folder isn't on this Mac.
  public var restoreTitle: String { isFolderAway ? "Restore To…" : "Restore" }

  /// When the selected file is too big for Quick Look, the sentence that says so.
  public func quickLookRefusal(for item: BackupItem) -> String? {
    guard item.kind == .file, let size = item.size, size > Self.quickLookLimit else { return nil }
    return
      "At \(bytes(size)) it is too big to preview here (Quick Look takes up to \(bytes(Self.quickLookLimit))). Restore it, or drag it to Finder, to open it."
  }

  public func canQuickLook(_ item: BackupItem) -> Bool {
    item.kind == .file && quickLookRefusal(for: item) == nil
  }

  /// Where a restore put the item, for the sidebar: "It is back in Finance as “Report.pages”."
  public func restoredSentence(path: String) -> String {
    let url = URL(fileURLWithPath: path)
    let folder = url.deletingLastPathComponent()
    let place =
      folder.standardizedFileURL.path == URL(fileURLWithPath: folderPath).standardizedFileURL.path
      ? folderName : folder.lastPathComponent
    return "It is back in \(place) as “\(url.lastPathComponent)”."
  }

  private func parentName(of item: BackupItem) -> String {
    item.parent.isEmpty
      ? folderName : String(item.parent.split(separator: "/").last ?? Substring(folderName))
  }

  /// While a column is being listed: what it waits for, or that Google Drive is being asked.
  public var listingSentence: String { busyWith?.waitingSentence ?? "Asking Google Drive…" }

  /// While items are copied into Finder by a drag: how many, and what they wait for.
  public var dragSentence: String? {
    guard dragsInFlight > 0 else { return nil }
    let copying =
      dragsInFlight == 1 ? "Copying 1 item to Finder." : "Copying \(dragsInFlight) items to Finder."
    return [copying, busyWith?.waitingSentence].compactMap(\.self).joined(separator: " ")
  }

  // MARK: The timeline

  /// The selected file's versions across the backups, newest first, and the one the backup
  /// shown holds; nil until its history is read, or for a folder.
  public func timeline(now: Date, calendar: Calendar = .current) -> FileTimeline? {
    guard let selection, !selection.isFolder, let history = histories[selection.path] else {
      return nil
    }
    let kept = Set(keptBackups.map(\.id))
    let versions = history.versions.sorted { $0.savedAt > $1.savedAt }
    let shownAt = backup?.savedAt
    let current = shownAt.flatMap { shown in versions.first { $0.savedAt <= shown } }
    let entries = versions.map { version in
      TimelineEntry(
        version, canShow: version.change != .removed && kept.contains(version.snapshotID),
        isCurrent: version == current && version.change != .removed, now: now,
        calendar: calendar)
    }
    return FileTimeline(
      entries: entries, sentence: timelineSentence(history, now: now, calendar: calendar))
  }

  /// What the list alone doesn't say. DirBuff knows a file's versions only from when this Mac
  /// began following the folder's changes (`trackedSince`): it says nothing of older backups but
  /// that they may hold others.
  private func timelineSentence(_ history: FileHistory, now: Date, calendar: Calendar)
    -> String?
  {
    let oldest = keptBackups.last?.savedAt
    let newest = keptBackups.first?.savedAt
    guard let since = history.trackedSince, newest.map({ since <= $0 }) ?? true else {
      // A backup taken over, not yet backed up here.
      return
        "Which backups hold other versions isn't known yet: this Mac follows changes to \(folderName) from its next backup on."
    }
    let day = versionDay(since, now: now, calendar: calendar)
    // The backup shown is from before then: nothing is known of its copy against the others.
    if let shown = backup?.savedAt, shown < since {
      return
        "Its versions are known only from \(day) on: what changed before then, and whether this older backup's copy is still the same, isn't known."
    }
    let followsAll = oldest.map { since <= $0 } ?? true
    let older = "Backups from before \(day) may hold other versions: choose one to look."
    // Older backups may hold more: that says all there is to say about what isn't listed.
    guard followsAll else {
      return history.versions.isEmpty ? "Unchanged since \(day). \(older)" : older
    }
    if history.versions.isEmpty {
      return
        "Unchanged since the first backup on \(versionDay(oldest ?? since, now: now, calendar: calendar))."
    }
    let known: String? =
      if history.hasEarlierVersionNotKept {
        FileTimeline.earlierNotKept
      } else if history.earlierVersionIsUnknown {
        "DirBuff is still checking which older backups are kept, so an earlier version may not be listed yet."
      } else {
        nil
      }
    return known
  }
}

/// The restic work Backup's schedule can be doing, which everything on the backup page waits
/// behind.
public enum BackupBusy: Sendable, Equatable {
  case backup
  /// The weekly check that reads a sample of the backup.
  case check
  /// Thinning the history and pruning.
  case upkeep

  /// What a column, a restore or a download says while it waits.
  public var waitingSentence: String {
    switch self {
    case .backup: "Waiting for the backup that's running to finish."
    case .check: "Waiting for the weekly check of the backup to finish."
    case .upkeep: "Waiting for the backup's tidy-up to finish."
    }
  }
}

/// One folder of one backup.
public struct BackupPlace: Sendable, Hashable {
  public var backupID: String
  /// Inside the backed-up folder; `""` for its top.
  public var path: String

  public init(backupID: String, path: String) {
    self.backupID = backupID
    self.path = path
  }
}

/// A folder column: the folder, its listing as far as it has got, and the item selected in it.
public struct BackupColumn: Sendable, Equatable, Identifiable {
  public var place: BackupPlace
  public var listing: BackupBrowserState.Listing
  /// The item selected in this column, by path; one in an earlier column is the folder on the way.
  public var selectedPath: String?
  /// Whether the selection itself is in this column, not only a folder on the way to it.
  public var isActive: Bool

  public var id: String { place.path }
}

/// A file's versions across the backups, newest first, with a sentence where the list alone
/// doesn't say it all.
public struct FileTimeline: Sendable, Equatable {
  public var entries: [TimelineEntry]
  public var sentence: String?

  /// Under the versions when the earliest isn't there.
  public static let earlierNotKept =
    "No earlier version is kept: older backups thin out with age, and none from before the first change is left."
}

/// One saved state of a file.
public struct TimelineEntry: Sendable, Equatable, Identifiable {
  public var version: BackupVersion
  /// "Today, 09:12", "Tue 20 Oct, 18:40", "20 Oct 2025, 18:40".
  public var when: String
  /// "Changed · 1.4 MB", "Added · 3 KB", "Deleted", "As backed up before 6 Nov".
  public var detail: String
  /// Whether its backup can be shown with the file in it: not a deletion, and still kept.
  public var canShow: Bool
  /// The content the backup shown holds.
  public var isCurrent: Bool

  public var id: String { version.snapshotID + version.change.rawValue }
  public var backupID: String { version.snapshotID }

  init(_ version: BackupVersion, canShow: Bool, isCurrent: Bool, now: Date, calendar: Calendar) {
    self.version = version
    self.canShow = canShow
    self.isCurrent = isCurrent
    when = versionMoment(version.savedAt, now: now, calendar: calendar)
    let size = version.size.map { " · \(bytes($0))" } ?? ""
    detail =
      if let replacedAt = version.replacedAt {
        "As backed up before \(versionDay(replacedAt, now: now, calendar: calendar))"
      } else {
        switch version.change {
        case .removed: "Deleted"
        case .added: "Added\(size)"
        case .changed: "Changed\(size)"
        }
      }
  }
}

/// When a backup was saved: "Today, 09:12", "Tue 20 Oct, 18:40", and with the year once it isn't
/// this year's.
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

/// A day, for "As backed up before 6 Nov": with the year once it isn't this year's.
func versionDay(_ date: Date, now: Date, calendar: Calendar) -> String {
  let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
  let isThisYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
  return isThisYear
    ? date.formatted(style.day().month(.abbreviated))
    : date.formatted(style.day().month(.abbreviated).year())
}

extension String {
  /// "PDF document" stays; "plain text" reads "Plain text", as Finder's Kind column has it.
  fileprivate var capitalizedFirst: String {
    prefix(1).uppercased() + dropFirst()
  }
}
