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

/// What Temporary does next, in numbers: the items that go together soonest, when, and their
/// size ("12 items go tomorrow · 1.3 GB"), or "Nothing goes yet".
func temporaryStatus(
  _ status: Engine.FolderStatus, settings: TemporarySettings, now: Date, calendar: Calendar
) -> String {
  let cleanUps = status.cleanUps(now: now, calendar: calendar)
  guard let soonest = cleanUps.first?.at else {
    // Empty on restart has no date: everything dated goes at the first clean-up after a restart.
    let atRestart = status.items.filter { $0.freshness != nil }
    guard settings.rule == .emptyOnRestart, !atRestart.isEmpty else { return "Nothing goes yet" }
    return "\(itemsGo(atRestart.count)) at restart · \(bytes(atRestart.size))"
  }
  // Today's clean-ups are told apart by the minute; later ones by the day.
  let together = cleanUps.filter {
    isTodays(cleanUp: soonest, now: now, calendar: calendar)
      ? $0.at == soonest : calendar.isDate($0.at, inSameDayAs: soonest)
  }.map(\.item)
  return
    "\(itemsGo(together.count)) \(cleanUpFromNow(soonest, now: now, calendar: calendar)) · \(bytes(together.size))"
}

/// "1 day", "14 days".
func days(_ count: Int) -> String {
  count == 1 ? "1 day" : "\(count) days"
}

extension [Item] {
  var size: Int64 { reduce(0) { $0 + $1.size } }
}
