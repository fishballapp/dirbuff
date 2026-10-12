import DirBuffCore
import DirBuffKit
import Foundation

/// What the menu-bar window shows.
public struct MenuBarState: Sendable, Equatable {
  public var headline: String
  public var subheadline: String
  public var isFinderExtensionOff: Bool
  public var licenceLine: LicenceLine?
  /// Off once the licence has ended: a folder added then can't be made Temporary.
  public var invitesFirstFolder: Bool
  public var forecast: [ForecastGroup]
  public var folders: [FolderSummary]
  public var recentRuns: [RecentRun]

  public var hasNoFolders: Bool { folders.isEmpty }
}

/// Items that go at the same moment in the same way: "In 23 min · Move to Bin", "Tomorrow · Move
/// to Bin".
public struct ForecastGroup: Sendable, Equatable, Identifiable {
  public var id: String { header }
  /// A countdown to each of today's clean-ups ("In 23 min", "In 42 sec"), later ones by the day
  /// ("Tomorrow", "Tue 20 Oct"), and "After a restart".
  public var when: String
  /// "Move to Bin", "Delete Permanently".
  public var action: String
  public var header: String { "\(when) · \(action)" }
  public var isPermanent: Bool
  /// Empty on restart's group: it goes at the first clean-up after a restart, whenever that is.
  public var isAtRestart: Bool
  public var items: [URL]
  public var names: [String] { items.map(\.lastPathComponent) }
  public var totalSize: String
}

public struct FolderSummary: Sendable, Equatable, Identifiable {
  public var id: Int64
  public var path: String
  public var name: String
  /// "30 days · Bin".
  public var rules: String
  /// "2 items go in 23 min", "Oldest goes in 2 days", "8.1 of 10 GB".
  public var distanceToGoing: String
}

/// One run's removals from one folder.
public struct RecentRun: Sendable, Equatable, Identifiable {
  public var id: Int64
  /// "12 items to the Bin".
  public var summary: String
  /// "Downloads · 09:00".
  public var detail: String
  public var journalEntryIDs: [Int64]
  public var canPutBack: Bool
  /// "Put 12 items back".
  public var putBackLabel: String
}

/// The forecast only looks a week ahead: a quiet week should look quiet.
private let forecastHorizonDays = 7
private let recentRunCount = 3

extension MenuBarState {
  public init(
    reports: [FolderReport],
    journal: [JournalEntry],
    freeSpace: Int64,
    isFinderExtensionOff: Bool,
    licence: Licence,
    now: Date,
    calendar: Calendar = .current,
    binName: String = SystemBin.name
  ) {
    let temporaryReports = reports.filter { $0.status?.isTagged != false }
    let next = nextCleanUp(after: now, calendar: calendar)
    let cleanUps = temporaryReports.compactMap(\.status).flatMap {
      $0.cleanUps(now: now, calendar: calendar).map(\.at)
    }
    let headline = {
      // Nothing is promised while DirBuff isn't allowed to clean.
      if !licence.mayClean { return "Cleaning is paused" }
      let atNext = cleanUps.count { $0 == next }
      if atNext > 0 { return "\(itemsGo(atNext)) in \(timeLeft(until: next, now: now))" }
      let today = cleanUps.count { isTodays(cleanUp: $0, now: now, calendar: calendar) }
      if today > 0 { return "\(itemsGo(today)) today" }
      let tomorrow = cleanUps.count { daysAhead($0, now: now, calendar: calendar) == 1 }
      if tomorrow > 0 { return "\(itemsGo(tomorrow)) tomorrow" }
      return "Nothing goes today"
    }()
    let noFolders = licence.refusal == nil ? "No Temporary folders yet" : "No Temporary folders"
    let folderCount =
      temporaryReports.count == 1 ? "1 folder" : "\(temporaryReports.count) folders"

    self.init(
      headline: temporaryReports.isEmpty ? noFolders : headline,
      subheadline: licence.whyPaused ?? "\(folderCount) · \(bytes(freeSpace)) free",
      isFinderExtensionOff: isFinderExtensionOff,
      licenceLine: licence.line,
      invitesFirstFolder: licence.refusal == nil,
      forecast: licence.mayClean
        ? forecastGroups(
          temporaryReports.compactMap { report in
            report.status.map { (report.folder.settings, $0) }
          },
          now: now, calendar: calendar, binName: binName)
        : [],
      folders: temporaryReports.compactMap { report in
        report.folder.id.map { id in
          FolderSummary(
            id: id,
            path: report.folder.path,
            name: report.name,
            rules: rules(report.folder.settings, binName: binName),
            distanceToGoing: distanceToGoing(
              report, licence: licence, now: now, calendar: calendar)
          )
        }
      },
      recentRuns: runs(journal, reports: reports, calendar: calendar, binName: binName)
    )
  }
}

extension Engine.FolderStatus {
  /// When each item a rule has a time for goes, soonest first: what's due now at the next
  /// clean-up, the rest at the clean-up after the Age rule finds it due. Never before the next
  /// clean-up, even when the status was read before the clock moved on.
  func cleanUps(now: Date, calendar: Calendar) -> [(item: Item, at: Date)] {
    let next = nextCleanUp(after: now, calendar: calendar)
    return dueNow.map { (item: $0.item, at: next) }
      + upcoming.filter { !isDue($0.item) }.map {
        (item: $0.item, at: max(next, nextCleanUp(after: $0.date, calendar: calendar)))
      }
  }

  private func isDue(_ item: Item) -> Bool {
    dueNow.contains { $0.item.url == item.url }
  }
}

/// When a forecast group happens, in the order a section lists them.
private enum Moment: Hashable, Comparable {
  /// One of today's clean-ups.
  case cleanUp(Date)
  /// Any of a later day's.
  case day(Date)
  case restart
}

private struct GroupKey: Hashable, Comparable {
  var moment: Moment
  var disposal: Disposal

  static func < (lhs: GroupKey, rhs: GroupKey) -> Bool {
    // Undoable first, then permanent: each is a section under its action.
    (lhs.disposal == .delete ? 1 : 0, lhs.moment) < (rhs.disposal == .delete ? 1 : 0, rhs.moment)
  }
}

/// What each folder's rules will remove over the coming week and after the next restart, grouped
/// by when and how: "In 23 min · Move to Bin", "Tomorrow · Move to Bin".
func forecastGroups(
  _ folders: [(settings: TemporarySettings, status: Engine.FolderStatus)],
  now: Date,
  calendar: Calendar,
  binName: String
) -> [ForecastGroup] {
  let horizon =
    calendar.date(
      byAdding: .day, value: forecastHorizonDays, to: calendar.startOfDay(for: now)) ?? now

  let entries: [(key: GroupKey, item: Item)] = folders.flatMap { settings, status in
    let disposal = settings.disposal
    let timed = status.cleanUps(now: now, calendar: calendar)
      .filter { $0.at < horizon }
      .map { item, at in
        let moment: Moment =
          isTodays(cleanUp: at, now: now, calendar: calendar)
          ? .cleanUp(at) : .day(calendar.startOfDay(for: at))
        return (key: GroupKey(moment: moment, disposal: disposal), item: item)
      }
    let listed = Set(timed.map(\.item.url))
    // Empty on restart takes everything still there, so it lists what no other group did.
    let atRestart =
      settings.emptyOnRestart
      ? status.items.filter { !listed.contains($0.url) }.map {
        (key: GroupKey(moment: .restart, disposal: disposal), item: $0)
      } : []
    return timed + atRestart
  }

  return Dictionary(grouping: entries, by: \.key)
    .sorted { $0.key < $1.key }
    .map { key, group in
      let when = {
        switch key.moment {
        case .cleanUp(let date): return "In \(timeLeft(until: date, now: now))"
        case .day(let date): return day(date, now: now, calendar: calendar)
        case .restart: return "After a restart"
        }
      }()
      let action = key.disposal == .delete ? "Delete Permanently" : "Move to \(binName)"
      return ForecastGroup(
        when: when,
        action: action,
        isPermanent: key.disposal == .delete,
        isAtRestart: key.moment == .restart,
        items: group.map(\.item.url),
        totalSize: bytes(group.reduce(0) { $0 + $1.item.size })
      )
    }
}

/// "30 days, under 10 GB · Bin".
func rules(_ settings: TemporarySettings, binName: String) -> String {
  let rules = [
    settings.maxAgeDays.map { "\($0) days" },
    settings.sizeLimit.map { "under \(bytes($0))" },
    settings.automatic ? "when disk is low" : nil,
    settings.emptyOnRestart ? "on restart" : nil,
  ].compactMap(\.self).joined(separator: ", ")
  guard let first = rules.first else { return "No rules on" }
  let disposal = settings.disposal == .delete ? "Delete" : binName
  return "\(first.uppercased())\(rules.dropFirst()) · \(disposal)"
}

func distanceToGoing(
  _ report: FolderReport, licence: Licence, now: Date, calendar: Calendar
) -> String {
  guard let status = report.status else { return "Can't read this folder" }
  guard status.isTagged else { return "Off" }
  guard licence.mayClean else { return "Paused" }
  let settings = report.folder.settings
  let cleanUps = status.cleanUps(now: now, calendar: calendar)
  let next = nextCleanUp(after: now, calendar: calendar)
  let atNext = cleanUps.count { $0.at == next }
  if atNext > 0 { return "\(itemsGo(atNext)) in \(timeLeft(until: next, now: now))" }
  if let limit = settings.sizeLimit { return "\(bytes(status.size)) of \(bytes(limit))" }
  if let first = cleanUps.first {
    return "Oldest goes \(cleanUpFromNow(first.at, now: now, calendar: calendar))"
  }
  if settings.emptyOnRestart, !status.items.isEmpty { return "Clears on restart" }
  if settings.automatic { return "Clears when disk is low" }
  return "Nothing to clear"
}

private func runs(
  _ journal: [JournalEntry],
  reports: [FolderReport],
  calendar: Calendar,
  binName: String
) -> [RecentRun] {
  let names = Dictionary(
    reports.compactMap { report in report.folder.id.map { ($0, report.name) } },
    uniquingKeysWith: { first, _ in first })
  struct RunKey: Hashable {
    var folderID: Int64
    var performedAt: Date
  }
  // A run journals all its removals from a folder at the same moment.
  return Dictionary(grouping: journal) {
    RunKey(folderID: $0.folderID, performedAt: $0.performedAt)
  }
  .sorted { $0.key.performedAt > $1.key.performedAt }
  .prefix(recentRunCount)
  .compactMap { key, entries in
    let ids = entries.compactMap(\.id)
    guard let first = ids.first else { return nil }
    let count = entries.count
    let isPutBack = entries.allSatisfy { $0.undoneAt != nil }
    let isPermanent = entries.contains { $0.disposal == .delete }
    let summary = {
      if isPermanent { return "\(items(count)) deleted permanently" }
      if isPutBack { return "\(items(count)) put back" }
      return "\(items(count)) to the \(binName)"
    }()
    return RecentRun(
      id: first,
      summary: summary,
      detail:
        "\(names[key.folderID] ?? "Removed folder") · \(key.performedAt.formatted(date: .omitted, time: .shortened))",
      journalEntryIDs: ids,
      canPutBack: !isPermanent && !isPutBack,
      putBackLabel: "Put \(items(count)) back"
    )
  }
}
