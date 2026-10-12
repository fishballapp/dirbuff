import DirBuffCore
import DirBuffKit
import Foundation

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
