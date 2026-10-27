import DirBuffCore
import DirBuffKit
import Foundation

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

/// What the folder's rules would remove at the next clean-up, over the coming week and after the
/// next restart.
public struct FolderPreview: Sendable, Equatable {
  public var headline: String
  public var forecast: [ForecastGroup]

  public static let loading = FolderPreview(headline: "Looking through the folder…", forecast: [])

  public init(headline: String, forecast: [ForecastGroup]) {
    self.headline = headline
    self.forecast = forecast
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
        return "\(itemsGo(thisWeek)) in \(timeLeft(until: next, now: now))"
      }
      if thisWeek > 0 { return "\(itemsGo(thisWeek)) this week" }
      let later = cleanUps.first.map {
        " The oldest item goes \(cleanUpFromNow($0.at, now: now, calendar: calendar))."
      }
      return "Nothing goes this week.\(later ?? "")"
    }()
    self.init(headline: headline, forecast: forecast)
  }
}

/// The forecast only looks a week ahead: a quiet week should look quiet.
private let forecastHorizonDays = 7

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
