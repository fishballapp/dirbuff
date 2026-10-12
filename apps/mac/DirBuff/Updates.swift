import Combine
import Sparkle

/// Sparkle checks the appcast once a day. The app menu's Check for Updates… asks now, and is off
/// while a check is already under way.
@MainActor
final class Updates: ObservableObject {
  @Published private(set) var canCheck = false
  private let controller = SPUStandardUpdaterController(
    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

  init() {
    controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
  }

  func check() {
    controller.checkForUpdates(nil)
  }
}
