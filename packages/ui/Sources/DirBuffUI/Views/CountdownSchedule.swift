import DirBuffCore
import Foundation
import SwiftUI

/// When a countdown to the next clean-up changes: on each minute of the clock, and on each second
/// in the minute before a clean-up. Clean-ups are on the hour, so the clock's own minutes and
/// seconds are where the countdown ticks.
public struct CountdownSchedule: TimelineSchedule {
  public var calendar: Calendar

  public init(calendar: Calendar = .current) {
    self.calendar = calendar
  }

  public func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
    var date = startDate
    return AnyIterator {
      defer { date = tick(after: date) }
      return date
    }
  }

  func tick(after date: Date) -> Date {
    let isLastMinute = nextCleanUp(after: date, calendar: calendar).timeIntervalSince(date) <= 60
    let unit: Calendar.Component = isLastMinute ? .second : .minute
    return calendar.dateInterval(of: unit, for: date)?.end ?? date.addingTimeInterval(1)
  }
}
