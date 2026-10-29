import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  /// A buff on the drag pasteboard, for drops on the app's own tiles. Its value is the buff's name.
  static let dirbuffBuff = UTType(exportedAs: "app.fishball.dirbuff.buff")
}

extension View {
  /// Makes the view a buff that drags onto a tile, or out onto a folder in Finder, as a lifted
  /// piece. A click that doesn't drag calls `onClick`; `onHover` follows the pointer.
  func buffDragSource(
    _ buff: Buff,
    onClick: @escaping () -> Void = {},
    onHover: @escaping (Bool) -> Void = { _ in }
  ) -> some View {
    overlay(BuffDragSource(buff: buff, onClick: onClick, onHover: onHover))
  }
}

/// SwiftUI's own dragging never tells the source where a file landed, so a buff drags from an
/// AppKit view laid over its row or piece.
private struct BuffDragSource: NSViewRepresentable {
  var buff: Buff
  var onClick: () -> Void
  var onHover: (Bool) -> Void

  @Environment(\.addBuffHost) private var host

  func makeNSView(context: Context) -> BuffDragView {
    BuffDragView(buff: buff, host: host)
  }

  func updateNSView(_ view: BuffDragView, context: Context) {
    view.buff = buff
    view.host = host
    view.onClick = onClick
    view.onHover = onHover
  }
}

private final class BuffDragView: NSView, NSDraggingSource {
  var buff: Buff
  var host: AddBuffHost
  var onClick: () -> Void = {}
  var onHover: (Bool) -> Void = { _ in }

  private var mouseDownEvent: NSEvent?
  private var isDragging = false

  init(buff: Buff, host: AddBuffHost) {
    self.buff = buff
    self.host = host
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  // The Buffs panel never takes the focus, so its first click has to start the drag.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: .zero,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self))
  }

  override func mouseEntered(with event: NSEvent) { onHover(true) }
  override func mouseExited(with event: NSEvent) { onHover(false) }

  override func mouseDown(with event: NSEvent) {
    mouseDownEvent = event
    isDragging = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard !isDragging, let start = mouseDownEvent else { return }
    let distance = hypot(
      event.locationInWindow.x - start.locationInWindow.x,
      event.locationInWindow.y - start.locationInWindow.y)
    guard distance > 3 else { return }
    isDragging = true
    beginDragging(with: start)
  }

  override func mouseUp(with event: NSEvent) {
    defer { mouseDownEvent = nil }
    guard !isDragging, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    onClick()
  }

  private func beginDragging(with event: NSEvent) {
    let host = host
    let buff = buff
    let provider = BuffPasteboardItem(
      buff: buff,
      delegate: BuffPromise(buff: buff) { folder in host.addToFinderFolder(buff, folder) })
    let item = NSDraggingItem(pasteboardWriter: provider)
    let image = liftedPieceImage(buff, appearance: effectiveAppearance)
    let point = convert(event.locationInWindow, from: nil)
    item.setDraggingFrame(
      NSRect(
        x: point.x - 24, y: point.y - image.size.height / 2,
        width: image.size.width, height: image.size.height),
      contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
    host.draggedBuff = buff
  }

  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    host.draggedBuff = nil
    host.dropFolderID = nil
  }
}

/// The drag's one pasteboard item: a file promise for Finder, and the buff's own type for the
/// app's tiles.
private final class BuffPasteboardItem: NSFilePromiseProvider {
  private let buffName: String
  // The provider holds its delegate weakly.
  private let promise: BuffPromise

  init(buff: Buff, delegate: BuffPromise) {
    buffName = buff.name
    promise = delegate
    super.init()
    fileType = UTType.data.identifier
    self.delegate = delegate
  }

  override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
    super.writableTypes(for: pasteboard) + [
      NSPasteboard.PasteboardType(UTType.dirbuffBuff.identifier)
    ]
  }

  override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
    guard type.rawValue == UTType.dirbuffBuff.identifier else {
      return super.pasteboardPropertyList(forType: type)
    }
    return buffName
  }
}

/// Finder hands the promise the folder it was dropped on. The promise writes nothing there and
/// reports success, so Finder ends the drag quietly and the folder gets the buff instead.
private final class BuffPromise: NSObject, NSFilePromiseProviderDelegate, Sendable {
  private let buff: Buff
  private let onDrop: @MainActor @Sendable (URL) -> Void

  init(buff: Buff, onDrop: @escaping @MainActor @Sendable (URL) -> Void) {
    self.buff = buff
    self.onDrop = onDrop
  }

  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    fileNameForType fileType: String
  ) -> String {
    buff.name
  }

  func filePromiseProvider(
    _ filePromiseProvider: NSFilePromiseProvider,
    writePromiseTo url: URL,
    completionHandler: @escaping ((any Error)?) -> Void
  ) {
    let folder = url.deletingLastPathComponent()
    Task { @MainActor in onDrop(folder) }
    completionHandler(nil)
  }
}

/// The piece as it looks in the air: lifted, with a deeper shadow, turned a little.
@MainActor
private func liftedPieceImage(_ buff: Buff, appearance: NSAppearance) -> NSImage {
  let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
  let renderer = ImageRenderer(
    content: BuffPiece(buff, isLifted: true)
      .padding(16)
      .environment(\.colorScheme, isDark ? .dark : .light))
  renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
  return renderer.nsImage ?? NSImage()
}
