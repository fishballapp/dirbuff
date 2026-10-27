import AppKit
import DirBuffUI
import SwiftUI

/// DirBuff's menu-bar item. Its menu holds the popover's SwiftUI layout as one item, not a
/// `MenuBarExtra` window: macOS keeps an auto-hidden menu bar shown while a menu is open.
@MainActor
final class StatusItem: NSObject {
  private let appModel: AppModel
  private let windows: WindowCoordinator
  private let menu = NSMenu()
  private var statusItem: NSStatusItem?
  /// The glyph for the folders as they stand, kept for an item that is shown later.
  private var glyph: MenuBarGlyphState = .atRest

  private lazy var popover = PopoverHostingView(
    rootView: MenuBarContainerView(
      appModel: appModel, windows: windows,
      closeMenu: { [weak self] in self?.menu.cancelTracking() }))

  init(appModel: AppModel, windows: WindowCoordinator) {
    self.appModel = appModel
    self.windows = windows
    super.init()
    menu.delegate = self
    menu.autoenablesItems = false
    let hosted = NSMenuItem()
    hosted.view = popover
    // A disabled item isn't highlighted, so macOS doesn't paint its blue over the popover on hover.
    hosted.isEnabled = false
    menu.addItem(hosted)
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit DirBuff", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
  }

  /// Shows the item while "Show in menu bar" is on, and keeps its glyph in step with the folders.
  func start() {
    NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.reconcileVisibility() } }
    observeGlyph()
    reconcileVisibility()
  }

  private func reconcileVisibility() {
    let isShown = UserDefaults.standard.object(forKey: AppModel.showInMenuBarKey) as? Bool ?? true
    if isShown, statusItem == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.menu = menu
      item.button?.image = MenuBarGlyph.image(glyph)
      item.button?.setAccessibilityLabel("DirBuff")
      statusItem = item
    }
    if !isShown, let statusItem {
      NSStatusBar.system.removeStatusItem(statusItem)
      self.statusItem = nil
    }
  }

  /// `withObservationTracking` fires once, so each change re-reads the glyph and arms the next read.
  private func observeGlyph() {
    let appModel = appModel
    glyph = withObservationTracking {
      appModel.popoverState(now: Date()).glyph
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeGlyph() }
    }
    statusItem?.button?.image = MenuBarGlyph.image(glyph)
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }
}

extension StatusItem: NSMenuDelegate {
  /// The popover is as tall as its folders are, read as the menu opens.
  func menuWillOpen(_ menu: NSMenu) {
    popover.frame.size = popover.fittingSize
    // The window gives its first control focus as it appears; clearing that after it has settled
    // leaves the menu with no focus ring drawn on a control.
    DispatchQueue.main.async { [weak self] in
      _ = self?.popover.window?.makeFirstResponder(nil)
    }
  }
}

/// Hosts the popover in the menu. It never takes first responder itself.
private final class PopoverHostingView: NSHostingView<MenuBarContainerView> {
  override var acceptsFirstResponder: Bool { false }
}
