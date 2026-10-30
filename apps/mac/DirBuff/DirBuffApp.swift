import SwiftUI

@main
struct DirBuffApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

  init() {
    // The adaptor's delegate already exists here, so the buffs can drop into Finder from launch.
    let app = _app.wrappedValue
    app.appModel.connectBuffDrops(openSettings: { app.windows.openSettings() })
  }

  /// The menu bar is an `NSStatusItem` the delegate owns, so the app has no window scene. The
  /// Settings scene exists to carry the app's commands.
  var body: some Scene {
    Settings { EmptyView() }
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
}

private struct CheckForUpdatesCommand: View {
  @ObservedObject var updates: Updates

  var body: some View {
    Button("Check for Updates…", action: updates.check)
      .disabled(!updates.canCheck)
  }
}
