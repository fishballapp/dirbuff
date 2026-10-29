import DirBuffCore
import DirBuffKit
import Foundation

/// Items cleared at the same moment in the same way: "In 23 min · Move to Bin", "Tomorrow · Move
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
  /// Empty on restart's group: it is cleared at the first clean-up after a restart, whenever that is.
  public var isAtRestart: Bool
  public var items: [URL]
  public var names: [String] { items.map(\.lastPathComponent) }
  public var totalSize: String
}

/// What the folder's rules would remove at the next clean-up, over the coming week and after the
/// next restart.
public struct FolderPreview: Sendable, Equatable {
  public var headline: String
  public var forecast: [ForecastGroup]
  /// What the folder's files page lists: every file still to be cleared, grouped by when.
  public var files: [UpcomingGroup]

  public static let loading = FolderPreview(headline: "Looking through the folder…", forecast: [])

  public init(headline: String, forecast: [ForecastGroup], files: [UpcomingGroup] = []) {
    self.headline = headline
    self.forecast = forecast
    self.files = files
  }

  public init(
    _ status: Engine.FolderStatus,
    settings: TemporarySettings,
    now: Date,
    calendar: Calendar = .current,
    binName: String = SystemBin.name
  ) {
    let forecast = forecastGroups(
      [(settings, status)], now: now, calendar: calendar, binName: binName)
    let thisWeek =
      forecast.filter { !$0.isAtRestart }
      .reduce(0) { $0 + $1.names.count }
    let cleanUps = status.cleanUps(now: now, calendar: calendar)
    let next = nextCleanUp(after: now, calendar: calendar)
    let atNext = cleanUps.count { $0.at == next }
    let headline = {
      if atNext > 0, atNext == thisWeek {
        return "\(itemsToClear(thisWeek)) in \(timeLeft(until: next, now: now))"
      }
      if thisWeek > 0 { return "\(itemsToClear(thisWeek)) this week" }
      let later = cleanUps.first.map {
        " The oldest item is cleared \(cleanUpFromNow($0.at, now: now, calendar: calendar))."
      }
      return "Nothing to clear this week.\(later ?? "")"
    }()
    self.init(
      headline: headline,
      forecast: forecast,
      files: upcomingGroups(status, settings: settings, now: now, calendar: calendar)
    )
  }
}

/// A file that is still to be cleared, as a row of the folder's files page.
public struct UpcomingFile: Sendable, Equatable, Identifiable {
  public var id: URL { url }
  public var url: URL
  public var byteCount: Int64
  /// When it last arrived or changed: "Sat 10 Oct".
  public var added: String
  /// "Mon, 14:00", or "At restart".
  public var clears: String

  public var name: String { url.lastPathComponent }
  public var size: String { bytes(byteCount) }
}

/// Files cleared together, in the order the files page lists them: the next clean-up that takes
/// anything, the rest of the next day something is cleared, then everything later.
public struct UpcomingGroup: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Hashable {
    case nextCleanUp
    case nextDay
    case later
    case restart
  }

  public var id: Kind { kind }
  public var kind: Kind
  /// "Tomorrow, 14:00", "Wed 28 Oct", "Later".
  public var title: String
  /// What follows the count and size in the header: "from Thu 29 Oct".
  public var detail: String?
  public var files: [UpcomingFile]

  /// "12 items · 1.3 GB", "37 items · from Thu 29 Oct".
  public var summary: String {
    let total = "\(items(files.count)) · \(bytes(files.reduce(0) { $0 + $1.byteCount }))"
    return detail.map { "\(total) · \($0)" } ?? total
  }

  /// The group's files whose name contains `query`, or nil when none do.
  func matching(_ query: String) -> UpcomingGroup? {
    let matches = files.filter { $0.name.localizedStandardContains(query) }
    guard !matches.isEmpty else { return nil }
    return UpcomingGroup(kind: kind, title: title, detail: nil, files: matches)
  }
}

extension [UpcomingGroup] {
  /// The groups that have a file whose name contains `query`, each holding only those files; all
  /// of them for a blank query.
  func matching(_ query: String) -> [UpcomingGroup] {
    query.isEmpty ? self : compactMap { $0.matching(query) }
  }
}

/// Why a folder's files page has nothing to list.
public enum FilesEmptiness: Sendable, Equatable {
  case cantRead
  case isPaused
  case isNotTemporary
  case nothingDue

  public var title: String {
    switch self {
    case .cantRead: "Can't read this folder"
    case .isPaused: "Cleaning is paused"
    case .isNotTemporary: "Temporary is off for this folder"
    case .nothingDue: "No files due for cleaning"
    }
  }

  public var detail: String {
    switch self {
    case .cantRead: "DirBuff needs access to show and clean its files."
    case .isPaused: "No files will be cleaned while it's paused."
    case .isNotTemporary: "No files will be cleaned from it."
    case .nothingDue: "Files will appear here when they're due."
    }
  }
}

/// Why the files page can't read a folder, said from the folder's own Temporary row: what
/// happened, whether the user has something to do, and the one fix.
public struct FilesProblem: Sendable, Equatable {
  /// "macOS took away access 3 days ago", "Can't find", "T7 Shuttle isn't connected".
  public var sentence: String
  /// A folder the sentence names, drawn as a pill after it.
  public var folderName: String?
  /// "Missing since Thu 22 Oct, 10:20".
  public var detail: String?
  /// What clears it; nil when nothing the user does will (a drive that isn't connected).
  public var fix: Fix?

  /// nil unless the folder's Temporary row says the folder itself can't be reached.
  public init?(_ folder: FolderState, now: Date) {
    guard let row = folder.buffs.first(where: { $0.buff == .temporary }) else { return nil }
    switch row.state {
    case .needsYou(.giveAccess):
      sentence =
        folder.accessLostAt.map { "\(row.status) \(timeSince($0, now: now)) ago" } ?? row.status
      folderName = nil
      detail = nil
      fix = .giveAccess
    case .needsYou(.locate):
      sentence = row.status
      folderName = row.statusFolder
      detail = row.setting
      fix = .locate
    case .paused(.driveUnplugged):
      sentence = row.status
      folderName = nil
      detail = nil
      fix = nil
    default:
      return nil
    }
  }
}

extension MainFolder {
  /// Why there is nothing to list, or nil when there is something.
  public func filesEmptiness(isPaused: Bool) -> FilesEmptiness? {
    if isPaused { return .isPaused }
    if !isReadable { return .cantRead }
    if !isTemporary { return .isNotTemporary }
    return preview.files.isEmpty ? .nothingDue : nil
  }
}

/// Every file the folder's rule will take, grouped by when: the next clean-up that takes
/// anything, the rest of the next day something is cleared, and everything later. Empty on restart's
/// files have no time, so they are one group of their own.
func upcomingGroups(
  _ status: Engine.FolderStatus,
  settings: TemporarySettings,
  now: Date,
  calendar: Calendar
) -> [UpcomingGroup] {
  let cleanUps = status.cleanUps(now: now, calendar: calendar).sorted {
    $0.at == $1.at ? $0.item.url.isNamedBefore($1.item.url) : $0.at < $1.at
  }
  let timed = timedGroups(cleanUps, now: now, calendar: calendar)
  guard settings.rule == .emptyOnRestart else { return timed }
  // A file already due is cleared at the next clean-up, so it isn't listed again for the restart.
  let timedURLs = Set(cleanUps.map(\.item.url))
  let atRestart = status.items.filter { $0.freshness != nil && !timedURLs.contains($0.url) }
  guard !atRestart.isEmpty else { return timed }
  return timed + [
    UpcomingGroup(
      kind: .restart,
      title: "At restart",
      detail: nil,
      files: atRestart.sorted { $0.url.isNamedBefore($1.url) }.map {
        file($0, clears: "At restart", calendar: calendar)
      })
  ]
}

private func timedGroups(
  _ cleanUps: [(item: Item, at: Date)], now: Date, calendar: Calendar
) -> [UpcomingGroup] {
  guard let first = cleanUps.first?.at else { return [] }
  let atFirst = cleanUps.filter { $0.at == first }
  let rest = cleanUps.filter { $0.at != first }
  let nextDay = rest.first.map { calendar.startOfDay(for: $0.at) }
  let onNextDay = rest.filter { calendar.startOfDay(for: $0.at) == nextDay }
  let later = rest.filter { calendar.startOfDay(for: $0.at) != nextDay }

  func files(_ cleanUps: [(item: Item, at: Date)]) -> [UpcomingFile] {
    cleanUps.map { item, at in
      file(item, clears: clearTime(at, now: now, calendar: calendar), calendar: calendar)
    }
  }

  let nextDayTitle = nextDay.map {
    calendar.isDate($0, inSameDayAs: first)
      ? "Later \(laterThat(first, now: now, calendar: calendar))"
      : day($0, now: now, calendar: calendar)
  }
  return [
    UpcomingGroup(
      kind: .nextCleanUp,
      title: "\(day(first, now: now, calendar: calendar)), \(time(first, calendar: calendar))",
      detail: nil, files: files(atFirst)),
    nextDayTitle.map {
      UpcomingGroup(kind: .nextDay, title: $0, detail: nil, files: files(onNextDay))
    },
    later.first.map {
      UpcomingGroup(
        kind: .later, title: "Later",
        detail: "from \(dayAndDate($0.at, calendar: calendar))", files: files(later))
    },
  ].compactMap(\.self)
}

private func file(_ item: Item, clears: String, calendar: Calendar) -> UpcomingFile {
  UpcomingFile(
    url: item.url,
    byteCount: item.size,
    added: item.freshness.map { dayAndDate($0, calendar: calendar) } ?? "—",
    clears: clears)
}

/// "Today, 09:00", "Mon, 14:00", and a date past a week.
private func clearTime(_ date: Date, now: Date, calendar: Calendar) -> String {
  let time = time(date, calendar: calendar)
  switch daysAhead(date, now: now, calendar: calendar) {
  case ...0: return "Today, \(time)"
  case 1..<7: return "\(date.formatted(dateStyle(calendar).weekday(.abbreviated))), \(time)"
  default: return "\(dayAndDate(date, calendar: calendar)), \(time)"
  }
}

/// "today", "tomorrow" or "on Thu 29 Oct", to follow "Later".
private func laterThat(_ date: Date, now: Date, calendar: Calendar) -> String {
  switch daysAhead(date, now: now, calendar: calendar) {
  case ...0: "today"
  case 1: "tomorrow"
  default: "on \(dayAndDate(date, calendar: calendar))"
  }
}

private func dateStyle(_ calendar: Calendar) -> Date.FormatStyle {
  Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
}

extension URL {
  /// Whether the file's name sorts first, the way Finder sorts: ignoring case, numbers by value.
  fileprivate func isNamedBefore(_ other: URL) -> Bool {
    lastPathComponent.localizedStandardCompare(other.lastPathComponent) == .orderedAscending
  }
}

/// "Thu 29 Oct".
private func dayAndDate(_ date: Date, calendar: Calendar) -> String {
  date.formatted(dateStyle(calendar).weekday(.abbreviated).day().month(.abbreviated))
}

/// "14:00" in the user's own clock style.
private func time(_ date: Date, calendar: Calendar) -> String {
  date.formatted(
    Date.FormatStyle(
      date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
}

/// The forecast only looks a week ahead: a quiet week should look quiet.
private let forecastHorizonDays = 7

extension Engine.FolderStatus {
  /// When each item a rule has a time for is cleared, soonest first: what's due now at the next
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
    // Empty on restart takes everything dated still there, so it lists what no other group did.
    let atRestart =
      settings.rule == .emptyOnRestart
      ? status.items.filter { $0.freshness != nil && !listed.contains($0.url) }.map {
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
