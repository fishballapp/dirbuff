import AppKit

/// Owns the app's model and windows from launch, so the Finder extension's `dirbuff://` URL opens
/// a window even when none is open yet.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let appModel: AppModel
  let updates: Updates
  lazy var windows = WindowCoordinator(appModel: appModel)

  override init() {
    let appModel = AppModel()
    self.appModel = appModel
    updates = Updates(licence: { appModel.licenceRecord })
    super.init()
  }

  /// Opened by the user, DirBuff shows its window; started by macOS at login, it stays in the menu
  /// bar.
  func applicationDidFinishLaunching(_ notification: Notification) {
    if !isLoginLaunch { windows.openMain() }
  }

  /// Opening DirBuff again while it runs, from Finder or Spotlight, brings its window back.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    windows.openMain()
    return false
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    urls.forEach(windows.open)
  }

  /// macOS marks the open-application event of a login launch, `SMAppService`'s included.
  private var isLoginLaunch: Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventID == kAEOpenApplication
    else { return false }
    return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
      == keyAELaunchedAsLogInItem
  }
}
