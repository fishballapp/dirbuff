import AppKit
import DirBuffKit
import DirBuffUI
import SwiftUI

/// Where the main window is, owned by the coordinator so `openMain` can drive it.
@Observable
@MainActor
final class MainWindowState {
  var navigation = MainNavigation()
}

/// Opens DirBuff's windows. An accessory app has no SwiftUI scene to open windows from while the
/// menu-bar window is closed (the Finder handoff), so they are plain AppKit windows: the main
/// window, Settings, and Setup.
@MainActor
final class WindowCoordinator {
  private let appModel: AppModel
  private let updates: Updates
  let mainWindowState = MainWindowState()
  private var windows: [String: NSWindow] = [:]

  init(appModel: AppModel, updates: Updates) {
    self.appModel = appModel
    self.updates = updates
  }

  /// Opens the main window, at the folder's page when `url` is a folder DirBuff knows.
  func openMain(selecting url: URL? = nil) {
    if let url, let report = appModel.report(for: url), let id = report.folder.id {
      openMain(route: .folder(id))
    } else {
      openMain(route: nil)
    }
  }

  /// Opens the main window at `route`, or where it was left.
  func openMain(route: MainRoute?) {
    if let route {
      mainWindowState.navigation = MainNavigation(opening: route)
    }
    showWindow(
      key: "main",
      create: {
        let window = NSWindow(
          contentRect: .zero,
          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
          backing: .buffered,
          defer: false)
        window.title = "DirBuff"
        window.toolbarStyle = .unified
        window.minSize = CGSize(width: 640, height: 420)
        window.contentViewController = NSHostingController(
          rootView: MainContainerView(
            appModel: self.appModel,
            windowState: self.mainWindowState,
            coordinator: self
          ))
        window.setContentSize(CGSize(width: 1240, height: 800))
        window.center()
        window.setFrameUsingName("DirBuffMain")
        window.setFrameAutosaveName("DirBuffMain")
        return window
      })
  }

  func openSettings() {
    showContentSized(key: "settings", title: "DirBuff Settings") {
      SettingsContainerView(appModel: appModel, updates: updates, coordinator: self)
    }
  }

  func openSetup() {
    showContentSized(key: "setup", title: "Set Up DirBuff") {
      SetupContainerView(appModel: appModel)
    }
  }

  func openKeyEntry() {
    showContentSized(key: "keyEntry", title: "Enter Licence Key") {
      KeyEntryContainerView(appModel: appModel, coordinator: self)
    }
  }

  func closeKeyEntry() {
    windows["keyEntry"]?.close()
  }

  private func showWindow(
    key: String,
    create: () -> NSWindow
  ) {
    NSApp.setActivationPolicy(.regular)
    // `activate()` only asks, and the app the user is in has to yield. Finder never does for its
    // extension's handoff, which left the window behind Finder, so this takes activation instead:
    // every window here opens because the user just asked for it.
    NSApp.activate(ignoringOtherApps: true)
    if let window = windows[key] {
      window.makeKeyAndOrderFront(nil)
      return
    }
    let window = create()
    window.isReleasedWhenClosed = false
    windows[key] = window
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in
      Task { @MainActor in
        self.windows[key] = nil
        if self.windows.isEmpty {
          NSApp.setActivationPolicy(.accessory)
        }
      }
    }
    window.makeKeyAndOrderFront(nil)
  }

  private func showContentSized(
    key: String,
    title: String,
    content: () -> some View
  ) {
    showWindow(key: key) {
      let window = NSWindow(
        contentRect: .zero,
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false)
      window.title = title
      // The window follows the content's own size as sections expand. Letting the hosting view size
      // it instead looped at 2x until AppKit threw: a grouped Form's height there depends on the
      // window's frame, which depended on the Form's height.
      let controller = NSHostingController(
        rootView: content()
          .fixedSize()
          .onGeometryChange(for: CGSize.self, of: \.size) { [weak window] size in
            window?.setContentSizeKeepingTop(size)
          })
      controller.sizingOptions = []
      window.contentViewController = controller
      window.setContentSize(controller.view.fittingSize)
      window.center()
      return window
    }
  }
}

extension NSWindow {
  /// Resizes the content, keeping the title bar where it is.
  fileprivate func setContentSizeKeepingTop(_ size: CGSize) {
    var next = frameRect(forContentRect: NSRect(origin: .zero, size: size))
    next.origin = NSPoint(x: frame.minX, y: frame.maxY - next.height)
    setFrame(next, display: true)
  }
}
