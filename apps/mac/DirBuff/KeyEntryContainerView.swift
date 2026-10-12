import DirBuffKit
import DirBuffUI
import SwiftUI

/// The key window's content: activates the pasted key, then closes and offers back the folders a
/// lapse made plain.
struct KeyEntryContainerView: View {
  var appModel: AppModel
  var coordinator: WindowCoordinator

  @State private var key = ""
  @State private var isActivating = false
  @State private var failure: PolarLicensing.Failure?

  var body: some View {
    KeyEntryView(
      key: $key,
      isActivating: isActivating,
      failure: failure,
      onActivate: activate,
      onCancel: coordinator.closeKeyEntry,
      onManageSubscription: appModel.openCustomerPortal
    )
  }

  private func activate() {
    isActivating = true
    failure = nil
    Task {
      let result = await appModel.activate(key: key)
      isActivating = false
      if let result {
        failure = result
      } else {
        coordinator.closeKeyEntry()
        await appModel.offerFoldersBack()
      }
    }
  }
}
