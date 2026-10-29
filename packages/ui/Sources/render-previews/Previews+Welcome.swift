import DirBuffCore
import DirBuffUI
import SwiftUI

/// The first-run window: before anything is on, with the first buff on, a stopped licence, nothing set up
/// yet, and opened again by a licensed user from Settings.
@MainActor
func welcomePreviews() -> [Preview] {
  func welcome(
    _ licence: Licence = .trial(daysLeft: 14),
    setup: SetupState = Samples.setup(),
    reports: [FolderReport] = [],
    chosen: WelcomeFolder? = nil,
    addedHere: Set<WelcomeFolder.ID> = [],
    refusal: String? = nil
  ) -> AnyView {
    // The window's transparent title bar, which these previews draw without.
    AnyView(
      VStack(spacing: 0) {
        Color.clear.frame(height: 28)
        WelcomeView(
          state: WelcomeState(
            setup: setup, licence: licence, folders: Samples.welcomeFolders, reports: reports,
            chosen: chosen, addedHere: addedHere, refusal: refusal, now: Samples.shownAt,
            calendar: Samples.utc, binName: Samples.binName),
          appIcon: Samples.appIcon)
      }
      .background(Palette.paper))
  }

  let downloads = Samples.welcomeFolders[0]
  let firstBuff = welcome(
    reports: [Samples.welcomeDownloadsReport()], chosen: downloads, addedHere: [downloads.id])

  return [
    ("welcome", welcome(), nil),
    ("welcome-first-buff", firstBuff, nil),
    // Change… on the folder's page set 30 days: the tile and the line follow it.
    (
      "welcome-first-buff-changed",
      welcome(
        reports: [Samples.welcomeDownloadsReport(TemporarySettings(maxAgeDays: 30))],
        chosen: downloads, addedHere: [downloads.id]),
      nil
    ),
    // Opened again from Settings, with Downloads already wearing it and chosen once more: shown as
    // done, with no Undo, and left as it was.
    (
      "welcome-already-on",
      welcome(
        .licensed, setup: Samples.setup(isNotificationsEnabled: true),
        reports: [Samples.welcomeDownloadsReport(TemporarySettings(maxAgeDays: 30))],
        chosen: downloads),
      nil
    ),
    (
      "welcome-nothing-set-up",
      welcome(setup: Samples.setup(isExtensionEnabled: false, isOpenAtLogin: false)),
      nil
    ),
    // A click on a tile while the trial has ended: the licence says why nothing went on.
    ("welcome-trial-ended", welcome(.trialEnded, refusal: Licence.trialEnded.refusal), nil),
    (
      "welcome-licensed",
      welcome(.licensed, setup: Samples.setup(isNotificationsEnabled: true)),
      nil
    ),
  ]
}
