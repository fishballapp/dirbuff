import Foundation

/// DirBuff clears its folders on the hour, by the clock, and at no other time, so a forecast can
/// name the moment each item goes.
///
/// The clean-up after `date`: the next hour on the clock, strictly later. An item due at `date`
/// goes then.
public func nextCleanUp(after date: Date, calendar: Calendar = .current) -> Date {
  calendar.dateInterval(of: .hour, for: date)?.end ?? date.addingTimeInterval(3_600)
}
