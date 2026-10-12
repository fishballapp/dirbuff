import DirBuffCore
import DirBuffKit

/// Where the licence stands until it's bought, with the one thing to do about it. It sits at the
/// foot of both windows: under the main window's sidebar, and as the menu-bar window's first item.
public struct LicenceLine: Sendable, Equatable {
  public enum Action: Sendable, Equatable {
    case buy
    case checkNow

    public var title: String {
      switch self {
      case .buy: "Buy DirBuff…"
      case .checkNow: "Check Licence Now"
      }
    }
  }

  public var text: String
  public var action: Action
  /// Whether DirBuff isn't cleaning; otherwise the trial is simply counting down.
  public var isWarning: Bool
}

extension Licence {
  public var line: LicenceLine? {
    switch self {
    case .trial: LicenceLine(text: status(key: nil), action: .buy, isWarning: false)
    case .licensed: nil
    case .trialEnded: LicenceLine(text: "Trial ended", action: .buy, isWarning: true)
    case .ended: LicenceLine(text: "Licence ended", action: .buy, isWarning: true)
    case .paused: LicenceLine(text: "Offline for 14 days", action: .checkNow, isWarning: true)
    }
  }

  /// Why cleaning is paused, under the headline that says it is.
  public var whyPaused: String? {
    switch self {
    case .trialEnded: "Your trial has ended. Folders are plain again."
    case .ended: "Your licence has ended. Folders are plain again."
    case .paused: "DirBuff couldn't check your licence for 14 days."
    case .trial, .licensed: nil
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
    case .ended: "Licence ended"
    }
  }

  /// Why a folder can't be made Temporary while the folders are plain.
  public var refusal: String? {
    switch self {
    case .trialEnded: "Your trial has ended. Buy DirBuff to make folders Temporary again."
    case .ended: "Your licence has ended. Buy DirBuff to make folders Temporary again."
    case .trial, .licensed, .paused: nil
    }
  }

  /// With a key there's a subscription to manage and a Mac to free; without one, a licence to get.
  public var hasKey: Bool {
    switch self {
    case .licensed, .paused: true
    case .trial, .trialEnded, .ended: false
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
