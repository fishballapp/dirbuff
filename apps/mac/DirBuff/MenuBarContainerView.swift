import DirBuffUI
import SwiftUI

/// The menu-bar popover's content: `MenuBarView` bound to the app model. Every action closes the
/// menu first, as a menu item does, then does its work.
struct MenuBarContainerView: View {
  var appModel: AppModel
  var windows: WindowCoordinator
  var closeMenu: () -> Void

  var body: some View {
    TimelineView(CountdownSchedule()) { timeline in
      MenuBarView(
        state: appModel.popoverState(now: timeline.date),
        onFix: { folderID, fix in
          closeMenu()
          appModel.perform(fix, on: folderID)
        },
        onOpen: {
          closeMenu()
          windows.openMain()
        },
        onSettings: {
          closeMenu()
          windows.openSettings()
        },
        onBuy: {
          closeMenu()
          appModel.openCheckout()
        },
        onCheckLicence: {
          closeMenu()
          Task { await appModel.checkLicenceNow() }
        }
      )
    }
  }
}
