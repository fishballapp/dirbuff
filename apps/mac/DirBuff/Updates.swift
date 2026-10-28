import AppKit
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
///
/// A bought licence is confirmed with Polar before an update is downloaded. `shouldProceedWithUpdate`
/// refuses any update the licence doesn't cover yet, so nothing unconfirmed is ever downloaded and
/// so nothing unconfirmed can install, on relaunch or on quit. While Polar is asked, the refusal is
/// silent; once an answer covers the build, a background check finds the update again and proceeds.
@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
  /// The UserDefaults key of the Settings switch for dev builds.
  static let getsDevBuildsKey = "getsDevBuilds"
  @Published private(set) var canCheck = false
  private let licence: @MainActor () -> LicenceRecord
  private let checkLicence: @MainActor () async -> Void
  private var controller: SPUStandardUpdaterController?
  /// Whether a licence check is under way for an update that waits on one.
  private var isConfirming = false

  init(
    licence: @escaping @MainActor () -> LicenceRecord,
    checkLicence: @escaping @MainActor () async -> Void
  ) {
    self.licence = licence
    self.checkLicence = checkLicence
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

  /// Decides, before the download, whether an update may be downloaded at all. An ended licence
  /// that doesn't cover the build is refused with the sentence. A key not yet confirmed for it is
  /// refused silently, and Polar is asked; a trial, or a confirmed build, proceeds.
  func updater(
    _ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
    updateCheck: SPUUpdateCheck
  ) throws {
    let release = release(of: updateItem)
    switch licence().gate(installing: release) {
    case .install:
      return
    case .refuse:
      throw refusal(for: updateItem)
    case .wait:
      confirmThenCheckAgain(installing: release)
      // Sparkle ends the cycle on this code without an alert or a log, which is what a wait needs.
      throw NSError(
        domain: SUSparkleErrorDomain,
        code: Int(SUError.installationCanceledError.rawValue))
    }
  }

  /// Asks Polar, then asks Sparkle to check again if the answer covers the build. A check that
  /// doesn't cover it, or Polar can't be reached, is left to Sparkle's own schedule.
  private func confirmThenCheckAgain(installing release: ReleaseDay?) {
    guard !isConfirming else { return }
    isConfirming = true
    Task {
      await checkLicence()
      isConfirming = false
      if licence().gate(installing: release) == .install {
        controller?.updater.checkForUpdatesInBackground()
      }
    }
  }

  private func release(of item: SUAppcastItem) -> ReleaseDay? {
    item.date.map(ReleaseDay.init(containing:))
  }

  private func refusal(for item: SUAppcastItem) -> NSError {
    NSError(
      domain: "app.fishball.dirbuff.updates", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "DirBuff \(item.displayVersionString) came out after your licence ended, so it wasn't installed; renewing gets it and every update after."
      ])
  }
}
