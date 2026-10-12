import Foundation

/// "1 item goes", "3 items go".
func itemsGo(_ count: Int) -> String {
  count == 1 ? "1 item goes" : "\(count) items go"
}

/// "1 item", "3 items".
func items(_ count: Int) -> String {
  count == 1 ? "1 item" : "\(count) items"
}

/// Whole days from `now`'s day to `date`'s: 0 today, 1 tomorrow.
func daysAhead(_ date: Date, now: Date, calendar: Calendar) -> Int {
  calendar.dateComponents(
    [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
  ).day ?? 0
}

/// "Today", "Tomorrow" or "Thu 16 Oct".
func day(_ date: Date, now: Date, calendar: Calendar) -> String {
  switch daysAhead(date, now: now, calendar: calendar) {
  case ...0: "Today"
  case 1: "Tomorrow"
  default: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
  }
}

/// "today", "tomorrow" or "in 5 days", to finish a sentence.
func dayFromNow(_ date: Date, now: Date, calendar: Calendar) -> String {
  switch daysAhead(date, now: now, calendar: calendar) {
  case ...0: "today"
  case 1: "tomorrow"
  case let days: "in \(days) days"
  }
}

/// How long until `date`: "23 min", "1 hr 5 min", and to the second in the last minute, "42 sec".
/// Rounded up, so it never says less time is left than is.
func timeLeft(until date: Date, now: Date) -> String {
  let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
  if seconds < 60 { return "\(seconds) sec" }
  let minutes = (seconds + 59) / 60
  let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
  if hours == 0 { return "\(minutes) min" }
  return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
}

/// Whether the clean-up at `date` is one of today's, which the forecast counts down to.
/// Midnight's counts, so late in the evening the next clean-up still shows its countdown.
func isTodays(cleanUp date: Date, now: Date, calendar: Calendar) -> Bool {
  let midnight =
    calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
  return date <= midnight
}

/// "in 23 min", "tomorrow" or "in 5 days": when the clean-up at `date` comes, to finish a
/// sentence.
func cleanUpFromNow(_ date: Date, now: Date, calendar: Calendar) -> String {
  isTodays(cleanUp: date, now: now, calendar: calendar)
    ? "in \(timeLeft(until: date, now: now))" : dayFromNow(date, now: now, calendar: calendar)
}

func bytes(_ count: Int64) -> String {
  count.formatted(.byteCount(style: .file))
}
