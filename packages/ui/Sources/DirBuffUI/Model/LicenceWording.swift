import DirBuffCore
import DirBuffKit
import Foundation

/// Where the licence stands until it's bought, with the one thing to do about it. It sits at the
/// foot of both windows: under the main window's sidebar, and at the menu-bar popover's foot.
public struct LicenceLine: Sendable, Equatable {
  public enum Action: Sendable, Equatable {
    case buy
    case renew
    case checkNow

    public var title: String {
      switch self {
      case .buy: "Buy…"
      case .renew: "Renew DirBuff…"
      case .checkNow: "Check Licence Now"
      }
    }

    /// Whether the action leads to a purchase, which a licence key goes with.
    public var isPurchase: Bool { self != .checkNow }
  }

  public var text: String
  public var action: Action
  /// Whether the line asks for the reader now: the trial's last days, or DirBuff isn't cleaning.
  /// Otherwise it sits quietly, the way to buy that is always there.
  public var isProminent: Bool

  /// How many days before the trial's end the line turns prominent.
  public static let trialPromptDays = 3
}

/// What a year of DirBuff costs the reader: 10 in dollars, pounds or euros, whichever Polar's
/// checkout will most likely charge. Polar prices by the buyer's IP; the Mac's time zone is the
/// nearest thing the app can read without asking. The time zones are the ones DirBuff's site
/// uses, so the two quote the same price.
public enum Pricing {
  public enum Currency: String, Sendable {
    case usd = "USD"
    case gbp = "GBP"
    case eur = "EUR"
  }

  /// The yearly price in every currency, in whole units: Polar's product lists 1000 minor units of
  /// each.
  static let yearlyAmount: Decimal = 10

  /// "£10", "10 €", "$10": the yearly price in the reader's likely currency, in their locale's style.
  public static func yearly(timeZone: TimeZone = .current, locale: Locale = .current) -> String {
    yearlyAmount.formatted(
      .currency(code: currency(for: timeZone).rawValue)
        .presentation(.narrow)
        .precision(.fractionLength(0))
        .locale(locale))
  }

  /// Pounds in the UK and the Crown dependencies, euros in the eurozone, dollars everywhere else.
  public static func currency(for timeZone: TimeZone) -> Currency {
    if gbpTimeZones.contains(timeZone.identifier) { return .gbp }
    if eurTimeZones.contains(timeZone.identifier) { return .eur }
    return .usd
  }

  private static let gbpTimeZones: Set<String> = [
    "Europe/London", "Europe/Belfast", "Europe/Guernsey", "Europe/Isle_of_Man", "Europe/Jersey",
  ]

  private static let eurTimeZones: Set<String> = [
    "Africa/Ceuta", "Asia/Famagusta", "Asia/Nicosia", "Atlantic/Azores", "Atlantic/Canary",
    "Atlantic/Madeira", "Europe/Amsterdam", "Europe/Andorra", "Europe/Athens", "Europe/Berlin",
    "Europe/Bratislava", "Europe/Brussels", "Europe/Busingen", "Europe/Dublin", "Europe/Helsinki",
    "Europe/Lisbon", "Europe/Ljubljana", "Europe/Luxembourg", "Europe/Madrid", "Europe/Malta",
    "Europe/Mariehamn", "Europe/Monaco", "Europe/Nicosia", "Europe/Paris", "Europe/Podgorica",
    "Europe/Riga", "Europe/Rome", "Europe/San_Marino", "Europe/Tallinn", "Europe/Vatican",
    "Europe/Vienna", "Europe/Vilnius", "Europe/Zagreb",
  ]
}

extension Licence {
  public var line: LicenceLine? {
    switch self {
    case .trial(let daysLeft):
      LicenceLine(
        text: status(key: nil), action: .buy,
        isProminent: daysLeft <= LicenceLine.trialPromptDays)
    case .licensed: nil
    case .trialEnded: LicenceLine(text: "Trial ended", action: .buy, isProminent: true)
    case .ended: LicenceLine(text: "Licence ended", action: .renew, isProminent: true)
    case .kept:
      LicenceLine(text: "Licence ended · version kept", action: .renew, isProminent: false)
    case .paused:
      LicenceLine(
        text: "DirBuff couldn't check your licence", action: .checkNow, isProminent: true)
    }
  }

  /// What the Buy button is called: a first purchase buys DirBuff, a later one renews.
  public var buyTitle: String {
    switch self {
    case .ended, .kept: LicenceLine.Action.renew.title
    case .trial, .trialEnded, .licensed, .paused: LicenceLine.Action.buy.title
    }
  }

  /// Settings' status: "Trial · 9 days left", "Licensed · ****-E63D8D".
  public func status(key: String?) -> String {
    switch self {
    case .trial(0): "Trial ends today"
    case .trial(1): "Trial ends tomorrow"
    case .trial(let daysLeft): "Trial · \(daysLeft) days left"
    case .trialEnded: "Trial ended"
    // Polar's own way of showing a key without giving it away.
    case .licensed: "Licensed · ****-\(key?.suffix(6) ?? "")"
    case .paused: "DirBuff couldn't check your licence"
    case .kept(let paidThrough): "Licence ended \(Self.date(paidThrough)) · you keep this version"
    case .ended(let paidThrough?):
      "Licence ended \(Self.date(paidThrough)) · renew to use this version"
    case .ended(nil): "Licence ended"
    }
  }

  fileprivate static func date(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.abbreviated).year())
  }

  /// Why a folder can't be made Temporary while the folders are plain.
  public var refusal: String? {
    switch self {
    case .trialEnded: "Your trial has ended. Buy DirBuff to make folders Temporary again."
    case .ended:
      "Your licence ended before this version came out. Renew to make folders Temporary again."
    case .trial, .licensed, .paused, .kept: nil
    }
  }

  /// With a key there's a subscription to manage and a Mac to free; without one, a licence to get.
  public var hasKey: Bool {
    switch self {
    case .licensed, .paused: true
    case .trial, .trialEnded, .ended, .kept: false
    }
  }
}

/// What Settings' Licence section says and offers: the state in a sentence, a line under it, and
/// the buttons, the first of which is the default when there's something to do.
public struct LicenceSettings: Sendable, Equatable {
  public enum Action: Sendable, Hashable {
    case buy
    case renew
    case checkNow
    case enterKey
    case deactivate
    case manageSubscription
  }

  public var headline: String
  public var detail: String
  /// The default button: the way back from a stop. A working licence has none.
  public var primary: Action?
  public var others: [Action]
  /// The yearly price the buttons quote (`Pricing.yearly`).
  public var price: String

  /// A button's title: "Buy for £10 a Year…".
  public func title(_ action: Action) -> String {
    switch action {
    case .buy: "Buy for \(price) a Year…"
    case .renew: "Renew for \(price) a Year…"
    case .checkNow: "Check Now"
    case .enterKey: "Enter Licence Key…"
    case .deactivate: "Deactivate This Mac…"
    case .manageSubscription: "Manage Subscription…"
    }
  }

  fileprivate static let whatItBuys = "gets every update, and supports an open source app."
}

extension Licence {
  /// The Licence section of Settings. `key` is the licence key, once there is one; `price` is the
  /// yearly price (`Pricing.yearly`).
  public func settings(key: String?, price: String) -> LicenceSettings {
    switch self {
    case .trial(let daysLeft):
      LicenceSettings(
        headline: Self.trialEnd(daysLeft: daysLeft),
        detail: "\(price) a year keeps every buff working, \(LicenceSettings.whatItBuys)",
        primary: .buy, others: [.enterKey], price: price)
    case .trialEnded:
      LicenceSettings(
        headline: "Your trial has ended",
        detail:
          "Every buff is paused. \(price) a year turns them all back on, \(LicenceSettings.whatItBuys)",
        primary: .buy, others: [.enterKey], price: price)
    case .licensed:
      LicenceSettings(
        headline: "Your licence is active", detail: "Key ****-\(key?.suffix(6) ?? "")",
        primary: nil, others: [.deactivate, .manageSubscription], price: price)
    case .paused:
      LicenceSettings(
        headline: "DirBuff couldn't check your licence",
        detail: "Every buff is paused. Check your connection, then try again.",
        primary: .checkNow, others: [.deactivate, .manageSubscription], price: price)
    case .kept:
      LicenceSettings(
        headline: "This version keeps working for good",
        detail: "Renew to get every later version.",
        primary: .renew, others: [.enterKey], price: price)
    case .ended:
      LicenceSettings(
        headline: "Your licence doesn't cover this version",
        detail: "Renew it to turn every buff back on.",
        primary: .renew, others: [.enterKey], price: price)
    }
  }

  private static func trialEnd(daysLeft: Int) -> String {
    switch daysLeft {
    case 0: "Your trial ends today"
    case 1: "Your trial ends tomorrow"
    default: "Your trial ends in \(daysLeft) days"
    }
  }

  /// The welcome window's foot: where the trial or licence stands, and what comes after. `price`
  /// is the yearly price (`Pricing.yearly`).
  public func welcomeLine(price: String) -> String {
    switch self {
    case .trial(let daysLeft) where daysLeft >= 14:
      "14-day trial, then \(price) a year"
    case .trial: "\(status(key: nil)), then \(price) a year"
    case .trialEnded: "Trial ended · \(price) a year"
    case .licensed, .paused: "Licensed"
    case .kept, .ended: "Licence ended · \(price) a year to renew"
    }
  }
}

extension PolarLicensing.Failure {
  /// What the key window says when activating fails.
  public var message: String {
    switch self {
    case .activationLimitReached:
      "This key is already active on 3 Macs. Free one in your Polar account, then try again."
    case .keyNotActive: "This key isn't active. It may have been cancelled or refunded."
    case .keyNotFound: "DirBuff doesn't recognise this key. Check it against your receipt email."
    case .unreachable: "Couldn't reach Polar. Check your connection and try again."
    }
  }
}
