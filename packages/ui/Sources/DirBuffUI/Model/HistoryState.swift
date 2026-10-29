import DirBuffCore
import DirBuffKit
import Foundation

/// A folder as History names it. A folder plain for good still has runs, so this comes from every
/// folder DirBuff knows, not only the shelf's.
public struct HistoryFolder: Sendable, Equatable, Identifiable {
  public var id: Int64
  public var name: String
  public var path: String
  /// Its mark now; nil while it wears no buff.
  public var mark: MarkState?

  public init(id: Int64, name: String, path: String, mark: MarkState?) {
    self.id = id
    self.name = name
    self.path = path
    self.mark = mark
  }

  /// Every folder in the reports' order, each with the mark its state gives it.
  public static func all(_ reports: [FolderReport], states: [FolderState]) -> [HistoryFolder] {
    let marks = Dictionary(uniqueKeysWithValues: states.map { ($0.id, $0.mark) })
    return reports.compactMap { report in
      report.folder.id.map {
        HistoryFolder(id: $0, name: report.name, path: report.folder.path, mark: marks[$0] ?? nil)
      }
    }
  }
}

/// History's list: every run, newest first, each the same two lines.
public struct HistoryState: Sendable, Equatable {
  public var runs: [HistoryRunRow]
  public var folders: [HistoryFolder]

  public init(runs: [HistoryRunRow] = [], folders: [HistoryFolder] = []) {
    self.runs = runs
    self.folders = folders
  }

  public init(
    _ runs: [RunSummary],
    folders: [HistoryFolder],
    now: Date,
    calendar: Calendar = .current
  ) {
    self.init(
      runs: runs.map { HistoryRunRow($0, now: now, calendar: calendar) }, folders: folders)
  }

  /// Every run, or only those that removed something from `folderID`, each with that folder's
  /// share.
  public func runs(touching folderID: Int64?) -> [HistoryRunRow] {
    guard let folderID else { return runs }
    return runs.compactMap { $0.share(of: folderID) }
  }

  /// "18 runs", or which folder's: "Downloads · 4 runs".
  public func subtitle(for folderID: Int64?) -> String {
    let count = runs(touching: folderID).count
    let counted = count == 1 ? "1 run" : "\(count) runs"
    guard let folder = folders.first(where: { $0.id == folderID }) else { return counted }
    return "\(folder.name) · \(counted)"
  }
}

/// One run in History's list.
public struct HistoryRunRow: Sendable, Equatable, Identifiable {
  public var id: Int64
  /// The buff that ran, whose symbol the row wears.
  public var buff: Buff
  /// "Today 09:00", "Fri 23 Oct 16:00".
  public var when: String
  /// "3 folders · 12 items · 3.4 GB"; in one folder's History, its share: "5 items · 2.3 GB".
  public var summary: String
  /// Each folder's share, by folder id.
  var folderSummaries: [Int64: String]

  public init(_ run: RunSummary, now: Date, calendar: Calendar = .current) {
    id = run.id
    buff = .temporary
    when = runTime(run.startedAt, now: now, calendar: calendar)
    summary = "\(folderCount(run.folderIDs.count)) · \(itemsAndBytes(run.itemCount, run.size))"
    folderSummaries = run.shares.mapValues { itemsAndBytes($0.itemCount, $0.size) }
  }

  /// This run as one folder's History shows it; nil if it removed nothing from the folder.
  func share(of folderID: Int64) -> HistoryRunRow? {
    folderSummaries[folderID].map { summary in
      var row = self
      row.summary = summary
      return row
    }
  }
}

/// A run's page: what it removed, folder by folder, and where each thing went.
public struct RunState: Sendable, Equatable {
  public var id: Int64
  public var buff: Buff
  /// "Today 09:00".
  public var title: String
  /// "Sun 25 Oct · 3 folders · 12 items · 3.4 GB · 9 items still in the Bin".
  public var subtitle: String
  public var groups: [RunFolderGroup]

  /// - Parameters:
  ///   - entries: What the run removed.
  ///   - folders: Every folder, in the order the run's groups follow.
  ///   - inBin: The entries whose items are still in the Bin, where the run put them.
  public init(
    _ run: RunSummary,
    entries: [JournalEntry],
    folders: [HistoryFolder],
    inBin: Set<Int64>,
    now: Date,
    calendar: Calendar = .current,
    binName: String = SystemBin.name
  ) {
    let byFolder = Dictionary(grouping: entries, by: \.folderID)
    let groups = folders.compactMap { folder in
      byFolder[folder.id].map {
        RunFolderGroup(
          folder, entries: $0, inBin: inBin, now: now, calendar: calendar, binName: binName)
      }
    }
    let stillInBin = groups.reduce(0) { $0 + $1.putBackEntryIDs.count }
    id = run.id
    buff = .temporary
    title = runTime(run.startedAt, now: now, calendar: calendar)
    subtitle = [
      runDay(run.startedAt, now: now, calendar: calendar), folderCount(run.folderIDs.count),
      itemsAndBytes(run.itemCount, run.size),
      stillInBin > 0 ? "\(items(stillInBin)) still in the \(binName)" : nil,
    ]
    .compactMap { $0 }
    .joined(separator: " · ")
    self.groups = groups
  }
}

/// One folder's part of a run.
public struct RunFolderGroup: Sendable, Equatable, Identifiable {
  /// A group longer than this shows `collapsedCount` files, then "and 3 more".
  static let longerThan = 5
  static let collapsedCount = 3

  public var id: Int64 { folder.id }
  public var folder: HistoryFolder
  /// "5 items · 2.3 GB".
  public var summary: String
  /// By name, as Finder sorts them.
  public var files: [RunFile]

  init(
    _ folder: HistoryFolder,
    entries: [JournalEntry],
    inBin: Set<Int64>,
    now: Date,
    calendar: Calendar,
    binName: String
  ) {
    self.folder = folder
    summary = itemsAndBytes(entries.count, entries.reduce(0) { $0 + $1.size })
    files =
      entries
      .compactMap { RunFile($0, inBin: inBin, now: now, calendar: calendar, binName: binName) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// What Put Back All brings back: every file still in the Bin.
  public var putBackEntryIDs: [Int64] {
    files.filter(\.isInBin).map(\.id)
  }

  /// The files a long group shows until "and 3 more" opens the rest.
  public func shownFiles(isExpanded: Bool) -> [RunFile] {
    isExpanded || files.count <= Self.longerThan
      ? files : Array(files.prefix(Self.collapsedCount))
  }

  /// "and 3 more", while some files are hidden.
  public func more(isExpanded: Bool) -> String? {
    let hidden = files.count - shownFiles(isExpanded: isExpanded).count
    return hidden > 0 ? "and \(hidden) more" : nil
  }
}

/// A file a run removed, and where it went.
public struct RunFile: Sendable, Equatable, Identifiable {
  public var id: Int64
  public var name: String
  /// "1.6 GB".
  public var size: String
  /// "In the Bin", "Emptied from the Bin", "Put back today, 10:12", "Deleted permanently".
  public var status: String
  /// Where it is in the Bin, while it's there to be put back or shown.
  public var binnedPath: String?

  public var isInBin: Bool { binnedPath != nil }

  init?(_ entry: JournalEntry, inBin: Set<Int64>, now: Date, calendar: Calendar, binName: String) {
    guard let id = entry.id else { return nil }
    self.id = id
    name = entry.name
    size = bytes(entry.size)
    let isInBin = entry.undoneAt == nil && entry.binnedPath != nil && inBin.contains(id)
    binnedPath = isInBin ? entry.binnedPath : nil
    status = {
      if let undoneAt = entry.undoneAt {
        return "Put back \(putBackDay(undoneAt, now: now, calendar: calendar))"
      }
      if entry.binnedPath == nil { return "Deleted permanently" }
      return isInBin ? "In the \(binName)" : "Emptied from the \(binName)"
    }()
  }
}

/// "5 items · 2.3 GB", in the app's one byte format.
private func itemsAndBytes(_ count: Int, _ size: Int64) -> String {
  "\(items(count)) · \(bytes(size))"
}

/// "1 folder", "3 folders".
private func folderCount(_ count: Int) -> String {
  count == 1 ? "1 folder" : "\(count) folders"
}

private func formatStyle(_ calendar: Calendar) -> Date.FormatStyle {
  Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
}

private func time(_ date: Date, calendar: Calendar) -> String {
  date.formatted(
    Date.FormatStyle(
      date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
}

/// "Fri 23 Oct", with the year once it isn't this one: "Fri 23 Oct 2025".
private func runDay(_ date: Date, now: Date, calendar: Calendar) -> String {
  let day = date.formatted(formatStyle(calendar).weekday(.abbreviated).day().month(.abbreviated))
  guard !calendar.isDate(date, equalTo: now, toGranularity: .year) else { return day }
  return "\(day) \(date.formatted(formatStyle(calendar).year()))"
}

/// When a run was, as its row and page title say it: "Today 09:00", "Yesterday 18:00",
/// "Fri 23 Oct 16:00".
private func runTime(_ date: Date, now: Date, calendar: Calendar) -> String {
  let day =
    switch daysAhead(date, now: now, calendar: calendar) {
    case 0: "Today"
    case -1: "Yesterday"
    default: runDay(date, now: now, calendar: calendar)
    }
  return "\(day) \(time(date, calendar: calendar))"
}

/// "today, 10:12", "yesterday, 10:12", "Fri 23 Oct, 10:12".
private func putBackDay(_ date: Date, now: Date, calendar: Calendar) -> String {
  let day =
    switch daysAhead(date, now: now, calendar: calendar) {
    case 0: "today"
    case -1: "yesterday"
    default: runDay(date, now: now, calendar: calendar)
    }
  return "\(day), \(time(date, calendar: calendar))"
}
