import Combine
import DirBuffCore
import Foundation
import Sparkle

/// Sparkle checks the appcast once a day. The app menu's Check for Updates… asks now, and is off
/// while a check is already under way.
///
/// Stable releases have no channel and reach everyone. A dev build of `main` is on the `dev`
/// channel, which Sparkle offers only to a copy that asks for it (`allowedChannels(for:)`) and
/// leaves out of the appcast it hands `bestValidUpdate(in:for:)`. Switching dev builds off keeps the
/// build installed until a stable one ranks above it.
///
/// A licence that has ended is offered only the versions it was paid up for: the
/// newest appcast item dated on or before the last day Polar confirmed the key. Anyone else, a
/// paying customer or someone on the trial, gets the newest.
@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
  /// The UserDefaults key of the Settings switch for dev builds.
  static let getsDevBuildsKey = "getsDevBuilds"

  @Published private(set) var canCheck = false
  private let licence: @MainActor () -> LicenceRecord
  private var controller: SPUStandardUpdaterController?

  init(licence: @escaping @MainActor () -> LicenceRecord) {
    self.licence = licence
    super.init()
    let controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    self.controller = controller
  }

  func check() {
    controller?.checkForUpdates(nil)
  }

  /// Looks now and says something only if there is an update, as the daily check does.
  func checkInBackground() {
    controller?.updater.checkForUpdatesInBackground()
  }

  // MARK: - SPUUpdaterDelegate

  func allowedChannels(for updater: SPUUpdater) -> Set<String> {
    UserDefaults.standard.bool(forKey: Self.getsDevBuildsKey) ? ["dev"] : []
  }

  /// The newest version the licence covers, if it is newer than this one. Otherwise, when later
  /// versions exist, the newest of them, which `updater(_:shouldProceedWithUpdate:…)` then turns
  /// down with the reason, so a check says why there is nothing to install.
  func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
    let record = licence()
    guard record.limitsUpdates else { return nil }

    let running =
      Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
    func isNewer(_ item: SUAppcastItem) -> Bool {
      SUStandardVersionComparator.default.compareVersion(running, toVersion: item.versionString)
        == .orderedAscending
    }
    func newest(_ items: [SUAppcastItem]) -> SUAppcastItem? {
      items.max { lhs, rhs in
        SUStandardVersionComparator.default.compareVersion(
          lhs.versionString, toVersion: rhs.versionString) == .orderedAscending
      }
    }

    let later = appcast.items.filter(isNewer)
    let covered = record.covered(later) { $0.date.map(ReleaseDay.init(containing:)) }
    return newest(covered) ?? newest(later) ?? SUAppcastItem.empty()
  }

  func updater(
    _ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
    updateCheck: SPUUpdateCheck
  ) throws {
    let record = licence()
    guard record.limitsUpdates else { return }
    let day = updateItem.date.map(ReleaseDay.init(containing:))
    guard let day, record.covers(release: day) else {
      throw NSError(
        domain: "app.fishball.dirbuff.updates", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "DirBuff \(updateItem.displayVersionString) came out after your licence ended. Renew DirBuff to get it and every update after; this version keeps working."
        ])
    }
  }
}
