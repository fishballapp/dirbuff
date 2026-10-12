import AppKit
import DirBuffCore
import DirBuffUI
import Foundation
import SwiftUI

@MainActor
func renderPNG<V: View>(
  view: V,
  outputURL: URL,
  appearanceName: NSAppearance.Name,
  fixedSize: CGSize? = nil,
  scale: CGFloat = 2.0
) throws {
  let appearance = NSAppearance(named: appearanceName)
  let wrapped =
    view
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

  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
  )
  window.appearance = appearance
  window.contentView = hostingView
  window.layoutIfNeeded()
  hostingView.layoutSubtreeIfNeeded()

  guard
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(size.width * scale),
      pixelsHigh: Int(size.height * scale),
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

@MainActor
func main() async {
  let targetDir: URL = {
    if CommandLine.arguments.count > 1 {
      return URL(fileURLWithPath: CommandLine.arguments[1])
    }
    return URL(fileURLWithPath: "projects/dirbuff/tmp-previews")
  }()

  try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
  print("Rendering previews to \(targetDir.path)...")

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
      "menubar-paused",
      AnyView(MenuBarView(state: Samples.menuBar(.paused))),
      nil
    ),

    // Main window states
    (
      "main-overview",
      AnyView(MainView(state: Samples.main, selection: .constant(.overview))),
      mainSize
    ),
    (
      "main-folder-on",
      AnyView(MainView(state: Samples.main, selection: .constant(.folder(1)))),
      mainSize
    ),
    (
      "main-folder-off",
      AnyView(MainView(state: Samples.main, selection: .constant(.folder(4)))),
      mainSize
    ),
    (
      "main-overview-trial",
      AnyView(MainView(state: Samples.main(.trial(daysLeft: 9)), selection: .constant(.overview))),
      mainSize
    ),
    (
      "main-overview-licence-ended",
      AnyView(MainView(state: Samples.main(.ended), selection: .constant(.overview))),
      mainSize
    ),
    (
      "main-folder-licence-ended",
      AnyView(MainView(state: Samples.main(.ended), selection: .constant(.folder(4)))),
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
      "settings-paused",
      AnyView(SettingsView(state: Samples.settings(.paused))),
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

  let appearances: [(suffix: String, name: NSAppearance.Name)] = [
    ("light", .aqua),
    ("dark", .darkAqua),
  ]

  for state in states {
    for appearance in appearances {
      let filename = "\(state.name)-\(appearance.suffix).png"
      let fileURL = targetDir.appendingPathComponent(filename)
      do {
        try renderPNG(
          view: state.view,
          outputURL: fileURL,
          appearanceName: appearance.name,
          fixedSize: state.size
        )
        print("  ✓ \(filename)")
      } catch {
        print("  ✗ \(filename): \(error)")
      }
    }
  }

  print("Done rendering \(states.count * appearances.count) preview images.")
}

await main()
