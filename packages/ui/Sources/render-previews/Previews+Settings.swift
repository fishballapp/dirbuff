import DirBuffCore
import DirBuffUI
import SwiftUI

/// Settings in each kind of licence, and the key window.
func settingsPreviews() -> [Preview] {
  [
    (
      "settings-trial",
      AnyView(SettingsView(state: Samples.settings(.trial(daysLeft: 9)))),
      nil
    ),
    (
      "settings-licensed",
      AnyView(SettingsView(state: Samples.settings(.licensed))),
      nil
    ),
    (
      "settings-licensed-dev-builds",
      AnyView(SettingsView(state: Samples.settings(.licensed, shouldGetDevBuilds: true))),
      nil
    ),
    (
      "settings-paused",
      AnyView(SettingsView(state: Samples.settings(.paused))),
      nil
    ),
    (
      "settings-kept",
      AnyView(SettingsView(state: Samples.settings(Samples.kept))),
      nil
    ),
    (
      "settings-ended",
      AnyView(SettingsView(state: Samples.settings(Samples.ended))),
      nil
    ),
    (
      "settings-trial-ended",
      AnyView(SettingsView(state: Samples.settings(.trialEnded))),
      nil
    ),

    // The key window
    (
      "key",
      AnyView(KeyEntryView(key: .constant(""))),
      nil
    ),
    (
      "key-limit",
      AnyView(
        KeyEntryView(
          key: .constant("DIRBUFF-9AD0419A-553D-4FB1-A8C2-F40AE9E63D8D"),
          failure: .activationLimitReached)),
      nil
    ),

  ]
}

extension Samples {
  static func settings(_ licence: Licence, shouldGetDevBuilds: Bool = false) -> SettingsState {
    SettingsState(
      openAtLogin: true, openAtLoginRequiresApproval: false, showInMenuBar: true,
      shouldGetDevBuilds: shouldGetDevBuilds, version: "0.1.3 (2126)", licence: licence,
      licenceKey: "DIRBUFF-9AD0419A-553D-4FB1-A8C2-F40AE9E63D8D")
  }
}
