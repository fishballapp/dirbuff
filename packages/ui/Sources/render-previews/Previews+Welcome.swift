import DirBuffUI
import SwiftUI

/// The first-run window.
func welcomePreviews() -> [Preview] {
  [
    (
      "setup",
      AnyView(SetupView(state: Samples.setup)),
      nil
    )
  ]
}

extension Samples {
  static let setup = SetupState(
    isExtensionEnabled: false, isOpenAtLogin: true, isOpenAtLoginRequiresApproval: false,
    isNotificationsEnabled: false)
}
