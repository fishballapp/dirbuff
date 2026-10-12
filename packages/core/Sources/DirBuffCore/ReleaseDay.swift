import Foundation

/// The day a version came out, in UTC: whole days, so a release and the licence check it is
/// compared with don't depend on the time of day or the Mac's time zone.
public struct ReleaseDay: Sendable, Equatable, Comparable {
  private static let calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()

  /// Days since 1970-01-01 in UTC.
  private let days: Int

  public init(containing date: Date) {
    days = Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
  }

  /// Reads `2026-10-12`, the form `release.sh` writes into `Info.plist`.
  public init?(_ text: String) {
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
      let day = Int(parts[2]),
      let date = Self.calendar.date(from: DateComponents(year: year, month: month, day: day))
    else { return nil }
    // The calendar rolls 2026-02-31 over to March; a date that isn't one is a broken build.
    let read = Self.calendar.dateComponents([.year, .month, .day], from: date)
    guard read.year == year, read.month == month, read.day == day else { return nil }
    self.init(containing: date)
  }

  public static func < (lhs: ReleaseDay, rhs: ReleaseDay) -> Bool { lhs.days < rhs.days }
}
