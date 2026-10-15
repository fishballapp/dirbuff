import AppKit
import DirBuffCore
import DirBuffUI
import Foundation
import SwiftUI

/// A borderless window that draws at 2× on any screen (the agents' Mac is 1×) and can become key.
final class RenderWindow: NSWindow {
  static let scale: CGFloat = 2
  override var backingScaleFactor: CGFloat { Self.scale }
  override var canBecomeKey: Bool { true }
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("render-previews: \(message)\n".utf8))
  exit(1)
}

func isVirtualMachine() -> Bool {
  var isPresent: Int32 = 0
  var size = MemoryLayout<Int32>.size
  return sysctlbyname("kern.hv_vmm_present", &isPresent, &size, nil, 0) == 0 && isPresent == 1
}

/// Handles events until `isDone` holds, for up to five seconds. Returns whether it held.
@MainActor
func handleEvents(until isDone: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(5)
  while !isDone() {
    guard Date() < deadline else { return false }
    let app = NSApplication.shared
    if let event = app.nextEvent(
      matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true)
    {
      app.sendEvent(event)
    }
  }
  return true
}

/// Draws `view` into a PNG. With `isKey`, the window is ordered front as the active app's key
/// window first: AppKit draws the switch and checkboxes in the accent colour only there.
@MainActor
func renderPNG<V: View>(
  view: V,
  outputURL: URL,
  appearanceName: NSAppearance.Name,
  fixedSize: CGSize?,
  isKey: Bool
) throws {
  let appearance = NSAppearance(named: appearanceName)
  let wrapped =
    view
    // Sidebar labels and the like draw in their key-window state, even in a window never shown.
    .environment(\.controlActiveState, .key)
    .background(Color(NSColor.windowBackgroundColor))

  let hostingView = NSHostingView(rootView: wrapped)
  hostingView.appearance = appearance

  let size: CGSize
  if let fixedSize {
    size = fixedSize
  } else {
    let fitting = hostingView.fittingSize
    size = CGSize(
      width: max(fitting.width, 320),
      height: max(fitting.height, 100)
    )
  }

  let window = RenderWindow(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
  )
  window.appearance = appearance
  window.contentView = hostingView
  defer { window.orderOut(nil) }
  if isKey {
    let app = NSApplication.shared
    window.makeKeyAndOrderFront(nil)
    // The cooperative `activate()` waits for the frontmost app to yield, which it never does here.
    app.activate(ignoringOtherApps: true)
    guard handleEvents(until: { app.isActive && window.isKeyWindow }) else {
      throw NSError(
        domain: "render-previews",
        code: 3,
        userInfo: [
          NSLocalizedDescriptionKey: "The window didn't become the active app's key window"
        ]
      )
    }
  }
  // NavigationSplitView settles over a few run-loop passes; one layout pass leaves it unplaced.
  for _ in 0..<5 {
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  }

  guard
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(size.width * RenderWindow.scale),
      pixelsHigh: Int(size.height * RenderWindow.scale),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  else {
    throw NSError(
      domain: "render-previews",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Failed to create NSBitmapImageRep"]
    )
  }

  rep.size = size
  hostingView.cacheDisplay(in: NSRect(origin: .zero, size: size), to: rep)

  guard let pngData = rep.representation(using: .png, properties: [:]) else {
    throw NSError(
      domain: "render-previews",
      code: 2,
      userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG data"]
    )
  }

  try pngData.write(to: outputURL)
}

let appearances: [(suffix: String, name: NSAppearance.Name)] = [
  ("light", .aqua),
  ("dark", .darkAqua),
]

/// Renders each state in light and dark into `directory`, named `<state>-<light|dark>.png`.
/// Returns whether every image rendered.
@MainActor
@discardableResult
func renderAll(
  _ states: [(name: String, view: AnyView, size: CGSize?)],
  into directory: URL,
  isKey: Bool = false
) -> Bool {
  var didRenderAll = true
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  print("Rendering previews to \(directory.path)...")
  for state in states {
    for appearance in appearances {
      let filename = "\(state.name)-\(appearance.suffix).png"
      let fileURL = directory.appendingPathComponent(filename)
      do {
        try renderPNG(
          view: state.view,
          outputURL: fileURL,
          appearanceName: appearance.name,
          fixedSize: state.size,
          isKey: isKey
        )
        print("  ✓ \(filename)")
      } catch {
        FileHandle.standardError.write(Data("  ✗ \(filename): \(error)\n".utf8))
        didRenderAll = false
      }
    }
  }
  print("Done rendering \(states.count * appearances.count) preview images.")
  return didRenderAll
}

/// The images the site shows (apps/site/scripts/render-images.sh): the main window on a
/// Temporary Downloads folder, and its folder panel at phone width. The sizes are fixed. They draw
/// as the active app's key window, so the app takes focus: only on the agents' Mac, a VM.
@MainActor
func renderSite(into directory: URL) {
  guard isVirtualMachine() else {
    fail(
      "site brings its windows to the front and takes focus, so it runs only in a VM. Use "
        + "`pnpm -F @dirbuff/site images`, which runs it on the agents' Mac.")
  }
  // A regular app, launched, is one that can be made active.
  NSApplication.shared.setActivationPolicy(.regular)
  NSApplication.shared.finishLaunching()
  let states: [(name: String, view: AnyView, size: CGSize?)] = [
    (
      "site-main",
      AnyView(
        MainView(state: Samples.site, selection: .constant(.folder(1)), binName: Samples.binName)),
      CGSize(width: 760, height: 760)
    ),
    (
      "site-folder-phone",
      AnyView(FolderDetailView(folder: Samples.site.folders[0], binName: Samples.binName)),
      CGSize(width: 390, height: 780)
    ),
  ]
  guard renderAll(states, into: directory, isKey: true) else {
    fail("not every site image rendered, so none should be used.")
  }
}

@MainActor
func main() {
  let arguments = CommandLine.arguments.dropFirst()
  if arguments.first == "site" {
    renderSite(into: URL(fileURLWithPath: arguments.dropFirst().first ?? "tmp-site"))
    return
  }
  let targetDir = URL(
    fileURLWithPath: arguments.first ?? "projects/dirbuff/tmp-previews")

  let mainSize = CGSize(width: 760, height: 560)

  let states: [(name: String, view: AnyView, size: CGSize?)] = [
    // Menu bar states
    (
      "menubar-busy",
      AnyView(MenuBarView(state: Samples.busy)),
      nil
    ),
    (
      "menubar-last-minute",
      AnyView(MenuBarView(state: Samples.lastMinute)),
      nil
    ),
    (
      "menubar-quiet",
      AnyView(MenuBarView(state: Samples.quiet)),
      nil
    ),
    (
      "menubar-nofolders",
      AnyView(MenuBarView(state: Samples.noFolders)),
      nil
    ),
    (
      "menubar-extensionoff",
      AnyView(MenuBarView(state: Samples.extensionOff)),
      nil
    ),
    (
      "menubar-trial",
      AnyView(MenuBarView(state: Samples.menuBar(.trial(daysLeft: 9)))),
      nil
    ),
    (
      "menubar-trial-ended",
      AnyView(MenuBarView(state: Samples.menuBar(.trialEnded))),
      nil
    ),
    (
      "menubar-ended",
      AnyView(MenuBarView(state: Samples.menuBar(Samples.ended))),
      nil
    ),
    (
      "menubar-kept",
      AnyView(MenuBarView(state: Samples.menuBar(Samples.kept))),
      nil
    ),
    (
      "menubar-paused",
      AnyView(MenuBarView(state: Samples.menuBar(.paused))),
      nil
    ),

    // Main window states
    (
      "main-overview",
      AnyView(
        MainView(state: Samples.main, selection: .constant(.overview), binName: Samples.binName)),
      mainSize
    ),
    (
      "main-folder-on",
      AnyView(
        MainView(state: Samples.main, selection: .constant(.folder(1)), binName: Samples.binName)),
      mainSize
    ),
    (
      "main-folder-off",
      AnyView(
        MainView(state: Samples.main, selection: .constant(.folder(4)), binName: Samples.binName)),
      mainSize
    ),
    (
      "main-overview-trial",
      AnyView(
        MainView(
          state: Samples.main(.trial(daysLeft: 9)), selection: .constant(.overview),
          binName: Samples.binName)),
      mainSize
    ),
    (
      "main-overview-licence-ended",
      AnyView(
        MainView(
          state: Samples.main(Samples.ended), selection: .constant(.overview),
          binName: Samples.binName)),
      mainSize
    ),
    (
      "main-overview-licence-kept",
      AnyView(
        MainView(
          state: Samples.main(Samples.kept), selection: .constant(.overview),
          binName: Samples.binName)),
      mainSize
    ),
    (
      "main-folder-licence-ended",
      AnyView(
        MainView(
          state: Samples.main(Samples.ended), selection: .constant(.folder(4)),
          binName: Samples.binName)),
      mainSize
    ),

    // Settings, in each kind of licence
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

    // Setup
    (
      "setup",
      AnyView(SetupView(state: Samples.setup)),
      nil
    ),
  ]

  renderAll(states, into: targetDir)
}

main()
