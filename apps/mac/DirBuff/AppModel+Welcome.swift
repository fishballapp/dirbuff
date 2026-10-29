import Foundation

extension AppModel {
  private static let hasSeenWelcomeKey = "hasSeenWelcome"

  /// Whether the welcome window has yet to open on its own: once, the first time DirBuff runs.
  var shouldWelcome: Bool { !UserDefaults.standard.bool(forKey: Self.hasSeenWelcomeKey) }

  func markWelcomeSeen() {
    UserDefaults.standard.set(true, forKey: Self.hasSeenWelcomeKey)
  }
}
