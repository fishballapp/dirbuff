import AppKit
import SwiftUI

/// + Buff in a toolbar: opens the buffs in a popover that tears off into the floating Buffs panel.
/// A click on a buff adds it to `target`; with no target, the buffs only drag.
struct AddBuffButton: View {
  var target: AddBuffTarget?
  /// False while every buff is paused.
  var isEnabled: Bool
  var actions: ShelfActions

  @State private var isShown = false

  var body: some View {
    Button {
      isShown.toggle()
    } label: {
      Label("Buff", systemImage: "plus")
        .labelStyle(.titleAndIcon)
    }
    .disabled(!isEnabled)
    .help("Add a buff to a folder")
    .background(
      DetachablePopover(isShown: $isShown) {
        AddBuffList(
          target: target,
          onAdd: { folderID, buff in
            isShown = false
            actions.addBuff(folderID, buff)
          },
          onChooseFolder: {
            isShown = false
            actions.chooseFolderForBuff(.temporary)
          })
      })
  }
}

/// An `NSPopover` under the view it backs. SwiftUI's own popover can't be torn off; this one
/// becomes the app's Buffs panel when it is.
private struct DetachablePopover<Content: View>: NSViewRepresentable {
  @Binding var isShown: Bool
  @ViewBuilder var content: () -> Content

  @Environment(\.addBuffHost) private var host

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    NSView()
  }

  func updateNSView(_ anchor: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.host = host
    coordinator.onClose = { isShown = false }
    let root = content().environment(\.addBuffHost, host)
    if let popover = coordinator.popover {
      (popover.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(root)
    }
    if isShown, coordinator.popover == nil, anchor.window != nil {
      coordinator.show(AnyView(root), from: anchor)
    } else if !isShown, let popover = coordinator.popover {
      popover.performClose(nil)
    }
  }

  static func dismantleNSView(_ anchor: NSView, coordinator: Coordinator) {
    coordinator.popover?.close()
  }

  @MainActor
  final class Coordinator: NSObject, NSPopoverDelegate {
    var popover: NSPopover?
    var host: AddBuffHost?
    var onClose: () -> Void = {}

    func show(_ root: AnyView, from anchor: NSView) {
      let popover = NSPopover()
      popover.behavior = .transient
      popover.animates = true
      popover.contentViewController = NSHostingController(rootView: root)
      popover.delegate = self
      self.popover = popover
      popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
      host?.buffsPanel() != nil
    }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
      host?.buffsPanel()
    }

    func popoverDidClose(_ notification: Notification) {
      popover = nil
      onClose()
    }
  }
}
