import DirBuffCore
import Foundation
import Testing

private func calendar(_ timeZone: String) -> Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: timeZone) ?? .gmt
  return calendar
}

/// 14:23:00 UTC on Tue 14 Oct 2026.
private let afternoon = Date(timeIntervalSince1970: 1_792_074_180)
private let hour: TimeInterval = 3_600

@Suite struct Schedule {
  @Test func cleansUpOnTheNextHour() {
    #expect(
      nextCleanUp(after: afternoon, calendar: calendar("UTC"))
        == afternoon.addingTimeInterval(37 * 60))
  }

  @Test func anItemDueOnTheHourGoesAtTheNext() {
    let threeOClock = afternoon.addingTimeInterval(37 * 60)
    #expect(
      nextCleanUp(after: threeOClock, calendar: calendar("UTC"))
        == threeOClock.addingTimeInterval(hour))
  }

  @Test func followsTheLocalClock() {
    // 14:23 UTC is 19:53 in India, whose clock is half an hour off UTC's: the next hour there is
    // 20:00, 14:30 UTC.
    #expect(
      nextCleanUp(after: afternoon, calendar: calendar("Asia/Kolkata"))
        == afternoon.addingTimeInterval(7 * 60))
  }
}
