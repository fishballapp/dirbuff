import Combine
import DirBuffCore
import Foundation
import Sparkle

/// Sparkle checks the appcast once a day. The app menu's Check for Updates… asks now, and is off
/// while a check is already under way.
///
/// A licence that has ended is offered only the versions it was paid up for: the
/// newest appcast item dated on or before the last day Polar confirmed the key. Anyone else, a
/// paying customer or someone on the trial, gets the newest.
@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
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

  // MARK: - SPUUpdaterDelegate

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
    let day = { (item: SUAppcastItem) in item.date.map(ReleaseDay.init(containing:)) }

    if let covered = record.newestCovered(appcast.items, releasedOn: day), isNewer(covered) {
      return covered
    }
    let later = appcast.items.filter(isNewer)
    return later.max { lhs, rhs in
      SUStandardVersionComparator.default.compareVersion(
        lhs.versionString, toVersion: rhs.versionString) == .orderedAscending
    } ?? SUAppcastItem.empty()
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
