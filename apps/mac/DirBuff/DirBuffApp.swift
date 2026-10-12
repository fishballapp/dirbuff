import AppKit
import DirBuffUI
import SwiftUI

@main
struct DirBuffApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var app
  @AppStorage(AppModel.showInMenuBarKey) private var showInMenuBar = true

  var body: some Scene {
    MenuBarExtra("DirBuff", image: "MenuBarIcon", isInserted: $showInMenuBar) {
      TimelineView(CountdownSchedule()) { timeline in
        menuBarView(now: timeline.date)
      }
    }
    .menuBarExtraStyle(.window)
    .commands {
      CommandGroup(after: .appInfo) {
        CheckForUpdatesCommand(updates: app.updates)
      }
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          app.windows.openSettings()
        }
        .keyboardShortcut(",")
      }
    }
  }

  private func menuBarView(now: Date) -> some View {
    MenuBarView(
      state: app.appModel.menuBarState(now: now),
      onTurnOnFinderExtension: closingMenu(app.appModel.openFinderExtensionsSettings),
      onSelectFolder: { folder in
        closingMenu { app.windows.openMain(selecting: URL(fileURLWithPath: folder.path)) }()
      },
      onUndo: { run in Task { await app.appModel.putBack(run) } },
      onOpen: closingMenu { app.windows.openMain() },
      onQuit: { NSApp.terminate(nil) },
      onBuy: closingMenu(app.appModel.openCheckout),
      onEnterKey: closingMenu { app.windows.openKeyEntry() },
      onCheckLicence: { Task { await app.appModel.checkLicenceNow() } }
    )
  }

  /// Closes the menu-bar window before `action` opens another, as a menu would; while one of its
  /// buttons is being clicked, the menu-bar window is the key window.
  private func closingMenu(_ action: @escaping () -> Void) -> () -> Void {
    {
      NSApp.keyWindow?.close()
      action()
    }
  }
}

private struct CheckForUpdatesCommand: View {
  @ObservedObject var updates: Updates

  var body: some View {
    Button("Check for Updates…", action: updates.check)
      .disabled(!updates.canCheck)
  }
}
