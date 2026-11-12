import AppKit
import DirBuffKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Makes a row of the backup page a drag source that Finder takes as a file promise: the item is
/// downloaded into wherever it's dropped, under the name Finder gives it, only once it is dropped.
/// A click selects the row, as the row's own tap would.
struct BackupItemDragSource: NSViewRepresentable {
  var item: BackupItem
  var onSelect: () -> Void
  /// What writes the item, made as the drag starts; nil when it can't be dragged now.
  var prepare: () -> BackupFilePromise.Write?

  func makeNSView(context: Context) -> DragView {
    let view = DragView()
    update(view)
    return view
  }

  func updateNSView(_ view: DragView, context: Context) {
    update(view)
  }

  private func update(_ view: DragView) {
    view.item = item
    view.onSelect = onSelect
    view.prepare = prepare
  }

  final class DragView: NSView, NSDraggingSource {
    var item: BackupItem?
    var onSelect: () -> Void = {}
    var prepare: () -> BackupFilePromise.Write? = { nil }
    private var downAt: NSPoint?
    /// The promise of the drag under way.
    private var promise: BackupFilePromise?

    override func mouseDown(with event: NSEvent) {
      downAt = convert(event.locationInWindow, from: nil)
      onSelect()
    }

    override func mouseDragged(with event: NSEvent) {
      guard let downAt, let item else { return }
      let point = convert(event.locationInWindow, from: nil)
      guard hypot(point.x - downAt.x, point.y - downAt.y) > 4 else { return }
      self.downAt = nil
      guard let write = prepare() else { return }
      let promise = BackupFilePromise(name: item.name, write: write)
      let provider = NSFilePromiseProvider(
        fileType: item.isFolder
          ? UTType.folder.identifier
          : (UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
            .identifier,
        delegate: promise)
      // The provider holds its delegate weakly: the promise keeps itself until it's done with.
      promise.holdUntilDone()
      self.promise = promise
      let draggingItem = NSDraggingItem(pasteboardWriter: provider)
      draggingItem.setDraggingFrame(
        NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
        contents: BackupItemIcon.image(for: item))
      beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
      downAt = nil
    }

    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
      context == .outsideApplication ? .copy : []
    }

    func draggingSession(
      _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
      // Dropped nowhere: no write will be asked for. Dropped on a target that never asks for the
      // file: it goes after a while, unless a write has begun by then, which runs to its end.
      if let promise {
        if operation.isEmpty {
          promise.releaseIfUnwritten()
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + BackupFilePromise.askedWithin) {
            promise.releaseIfUnwritten()
          }
        }
      }
      promise = nil
    }
  }
}

/// Writes the promised item when Finder asks, on a queue of its own. It keeps itself, and so
/// what writes the item, alive from the start of its drag until the write has ended, or the drag
/// ended with no drop: the row that started it may be gone by then, or the page closed.
public final class BackupFilePromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
  /// Writes the item to the URL Finder gives; throws if it couldn't.
  public typealias Write = @Sendable (URL) async throws -> Void

  private let name: String
  private let write: Write
  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    return queue
  }()
  private var isWriting = false

  /// How long after its drop a promise waits to be asked for its file. Finder asks at once.
  static let askedWithin: TimeInterval = 300

  /// Every promise whose drag is under way or whose write hasn't finished.
  private static let held = OSAllocatedUnfairLock(initialState: Set<BackupFilePromise>())

  init(name: String, write: @escaping Write) {
    self.name = name
    self.write = write
  }

  func holdUntilDone() {
    _ = Self.held.withLock { $0.insert(self) }
  }

  /// Its drag ended with no drop, or its drop never asked for the file: unless a write was asked
  /// of it after all, it goes.
  func releaseIfUnwritten() {
    Self.held.withLock { held in
      if !isWriting { held.remove(self) }
    }
  }

  private func release() {
    _ = Self.held.withLock { $0.remove(self) }
  }

  public func filePromiseProvider(
    _ provider: NSFilePromiseProvider, fileNameForType fileType: String
  ) -> String { name }

  public func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { queue }

  public func filePromiseProvider(
    _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
    completionHandler: @escaping (Error?) -> Void
  ) {
    Self.held.withLock { _ in isWriting = true }
    let done = UncheckedSendable(completionHandler)
    Task {
      do {
        try await write(url)
        done.value(nil)
      } catch {
        done.value(error)
      }
      release()
    }
  }
}

/// A value the compiler can't prove sendable, handed to one task that calls it once.
private struct UncheckedSendable<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}

/// The icon Finder would give an item of that name and kind.
enum BackupItemIcon {
  static func image(for item: BackupItem) -> NSImage {
    switch item.kind {
    case .folder: NSWorkspace.shared.icon(for: .folder)
    case .link: NSWorkspace.shared.icon(for: .aliasFile)
    case .file:
      NSWorkspace.shared.icon(
        for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
    }
  }
}
