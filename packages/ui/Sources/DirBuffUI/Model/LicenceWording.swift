import DirBuffCore
import DirBuffKit
import Foundation

/// Where the licence stands until it's bought, with the one thing to do about it. It sits at the
/// foot of both windows: under the main window's sidebar, and as the menu-bar window's first item.
public struct LicenceLine: Sendable, Equatable {
  public enum Action: Sendable, Equatable {
    case buy
    case renew
    case checkNow

    public var title: String {
      switch self {
      case .buy: "Support DirBuff…"
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
    case .paused: LicenceLine(text: "Offline for 14 days", action: .checkNow, isWarning: true)
    }
  }

  /// What the Buy button is called: a first purchase supports DirBuff, a later one renews.
  public var buyTitle: String {
    switch self {
    case .ended, .kept: LicenceLine.Action.renew.title
    case .trial, .trialEnded, .licensed, .paused: LicenceLine.Action.buy.title
    }
  }

  /// Why cleaning is paused, under the headline that says it is.
  public var whyPaused: String? {
    switch self {
    case .trialEnded: "Your trial has ended. Folders are plain again."
    case .ended: "Your licence ended before this version came out. Renew to use it."
    case .paused: "DirBuff couldn't check your licence for 14 days."
    case .trial, .licensed, .kept: nil
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
    case .paused: "Paused · couldn't reach Polar for 14 days"
    case .kept(let paidThrough): "Licence ended \(Self.date(paidThrough)) · you keep this version"
    case .ended(let paidThrough?):
      "Licence ended \(Self.date(paidThrough)) · renew to use this version"
    case .ended(nil): "Licence ended"
    }
  }

  private static func date(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.abbreviated).year())
  }

  /// Why a folder can't be made Temporary while the folders are plain.
  public var refusal: String? {
    switch self {
    case .trialEnded: "Your trial has ended. Support DirBuff to make folders Temporary again."
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
