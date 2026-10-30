import DirBuffCore
import DirBuffKit
import Foundation

/// Temporary's setting in a few words: "Older than 14 days, to the Bin", "Under 50 GB, deleted
/// permanently".
func temporarySetting(_ settings: TemporarySettings, binName: String) -> String {
  let rule =
    switch settings.rule {
    case .age: "Older than \(days(settings.maxAgeDays))"
    case .size: "Under \(bytes(settings.sizeLimit))"
    case .automatic: "When the disk is nearly full"
    case .emptyOnRestart: "Emptied at restart"
    }
  let destination = settings.disposal == .delete ? "deleted permanently" : "to the \(binName)"
  return "\(rule), \(destination)"
}

/// What Temporary does next, in numbers: the items that clear together soonest, when, and their
/// size ("12 items to clear tomorrow · 1.3 GB"), or "Nothing to clear yet".
func temporaryStatus(
  _ status: Engine.FolderStatus, settings: TemporarySettings, now: Date, calendar: Calendar
) -> String {
  let cleanUps = status.cleanUps(now: now, calendar: calendar)
  guard let soonest = cleanUps.first?.at else {
    let atRestart = status.clearedAtRestart(settings)
    guard !atRestart.isEmpty else { return "Nothing to clear yet" }
    return "\(itemsToClear(atRestart.count)) at restart · \(bytes(atRestart.size))"
  }
  let together = soonestTogether(cleanUps, now: now, calendar: calendar).map(\.item)
  return
    "\(itemsToClear(together.count)) \(cleanUpFromNow(soonest, now: now, calendar: calendar)) · \(bytes(together.size))"
}

/// The items cleared first, together, as the status line counts them: today's by the minute,
/// later ones by the day.
func soonestTogether(
  _ cleanUps: [(item: Item, at: Date)], now: Date, calendar: Calendar
) -> [(item: Item, at: Date)] {
  guard let soonest = cleanUps.first?.at else { return [] }
  let byMinute = isTodays(cleanUp: soonest, now: now, calendar: calendar)
  return cleanUps.filter {
    byMinute ? $0.at == soonest : calendar.isDate($0.at, inSameDayAs: soonest)
  }
}

/// "1 day", "14 days".
func days(_ count: Int) -> String {
  count == 1 ? "1 day" : "\(count) days"
}

extension Engine.FolderStatus {
  /// Empty on restart has no date: everything dated clears at the first clean-up after a restart.
  func clearedAtRestart(_ settings: TemporarySettings) -> [Item] {
    settings.rule == .emptyOnRestart ? items.filter { $0.freshness != nil } : []
  }
}

extension [Item] {
  var size: Int64 { reduce(0) { $0 + $1.size } }
}

extension TemporarySettings {
  /// The Age rule's days a pop-up offers, on the folder page and the card after a drop: a week,
  /// two, a month and three, with the days the folder has, in order.
  public static func ageDayChoices(including days: Int?) -> [Int] {
    Set([7, 14, 30, defaultMaxAgeDays] + (days.map { [$0] } ?? [])).sorted()
  }
}
