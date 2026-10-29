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
  /// Whether DirBuff isn't cleaning; otherwise the trial is simply counting down.
  public var isWarning: Bool
}

/// What DirBuff costs, said wherever it asks for it: the price supports its development.
public enum Pricing {
  public static let yearly = "$10, £10 or €10 a year"
  public static let pitch =
    "DirBuff is open source (GPL-3.0). A licence, \(yearly), supports its development and gets you every update. Stop whenever you like: you keep the version you have, and it keeps working."
}

extension Licence {
  public var line: LicenceLine? {
    switch self {
    case .trial: LicenceLine(text: status(key: nil), action: .buy, isWarning: false)
    case .licensed: nil
    case .trialEnded: LicenceLine(text: "Trial ended", action: .buy, isWarning: true)
    case .ended: LicenceLine(text: "Licence ended", action: .renew, isWarning: true)
    case .kept: LicenceLine(text: "Licence ended · version kept", action: .renew, isWarning: false)
    case .paused:
      LicenceLine(
        text: "DirBuff couldn't check your licence", action: .checkNow, isWarning: true)
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

    public var title: String {
      switch self {
      case .buy: "Buy for $10 a Year…"
      case .renew: "Renew for $10 a Year…"
      case .checkNow: "Check Now"
      case .enterKey: "Enter Licence Key…"
      case .deactivate: "Deactivate This Mac…"
      case .manageSubscription: "Manage Subscription…"
      }
    }
  }

  public var headline: String
  public var detail: String
  /// The default button: the way back from a stop. A working licence has none.
  public var primary: Action?
  public var others: [Action]

  fileprivate static let whatItBuys = "gets every update, and supports an open source app."
}

extension Licence {
  /// The Licence section of Settings. `key` is the licence key, once there is one.
  public func settings(key: String?) -> LicenceSettings {
    switch self {
    case .trial(let daysLeft):
      LicenceSettings(
        headline: Self.trialEnd(daysLeft: daysLeft),
        detail: "$10 a year keeps every buff working, \(LicenceSettings.whatItBuys)",
        primary: .buy, others: [.enterKey])
    case .trialEnded:
      LicenceSettings(
        headline: "Your trial has ended",
        detail:
          "Every buff is paused. $10 a year turns them all back on, \(LicenceSettings.whatItBuys)",
        primary: .buy, others: [.enterKey])
    case .licensed:
      LicenceSettings(
        headline: "Your licence is active", detail: "Key ****-\(key?.suffix(6) ?? "")",
        primary: nil, others: [.deactivate, .manageSubscription])
    case .paused:
      LicenceSettings(
        headline: "DirBuff couldn't check your licence",
        detail: "Every buff is paused. Check your connection, then try again.",
        primary: .checkNow, others: [.deactivate, .manageSubscription])
    case .kept:
      LicenceSettings(
        headline: "This version keeps working for good",
        detail: "Renew to get every later version.",
        primary: .renew, others: [.enterKey])
    case .ended:
      LicenceSettings(
        headline: "Your licence doesn't cover this version",
        detail: "Renew it to turn every buff back on.",
        primary: .renew, others: [.enterKey])
    }
  }

  private static func trialEnd(daysLeft: Int) -> String {
    switch daysLeft {
    case 0: "Your trial ends today"
    case 1: "Your trial ends tomorrow"
    default: "Your trial ends in \(daysLeft) days"
    }
  }

  /// The welcome window's foot: where the trial or licence stands, and what comes after.
  public var welcomeLine: String {
    switch self {
    case .trial(let daysLeft) where daysLeft >= 14:
      "14-day trial, then $10 a year"
    case .trial: "\(status(key: nil)), then $10 a year"
    case .trialEnded: "Trial ended · $10 a year"
    case .licensed, .paused: "Licensed"
    case .kept, .ended: "Licence ended · $10 a year to renew"
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
