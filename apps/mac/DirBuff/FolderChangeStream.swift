import CoreServices
import Foundation

/// An FSEvents stream on one folder: tells when something in it changed. A change while DirBuff
/// wasn't running is told as soon as the stream starts, if the stream resumes from the event ID
/// it was left at (`resuming`).
final class FolderChangeStream: @unchecked Sendable {
  /// Where a stream can pick up again: the newest event it need not tell, on the volume whose
  /// journal gave the ID. Another volume UUID means the journal was reset, so the ID means nothing.
  struct Place: Codable, Equatable, Sendable {
    var eventID: UInt64
    var volumeUUID: String
  }

  /// Hears the newest event ID of each batch of changes.
  private final class Handler: @unchecked Sendable {
    let onChange: @Sendable (UInt64) -> Void
    init(onChange: @escaping @Sendable (UInt64) -> Void) { self.onChange = onChange }
  }

  private let handler: Handler
  private var stream: FSEventStreamRef?
  private let queue = DispatchQueue(label: "app.fishball.dirbuff.folder-changes", qos: .utility)

  /// Nil if macOS won't watch the path. `resuming` replays what changed since that event; nil
  /// watches from now on.
  init?(
    path: String, resuming eventID: UInt64? = nil, onChange: @escaping @Sendable (UInt64) -> Void
  ) {
    handler = Handler(onChange: onChange)
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(handler).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, _, flags, ids in
      guard let info else { return }
      let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
      // The end of a replay marks no change.
      let changes = (0..<count).filter {
        flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0
      }
      guard let newest = changes.map({ ids[$0] }).max() else { return }
      handler.onChange(newest)
    }
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, [path] as CFArray,
        eventID ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot))
    else { return nil }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      stop()
      return nil
    }
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  deinit { stop() }

  /// The newest event ID on this Mac: a backup that starts now has seen every change up to it.
  static func currentEventID() -> UInt64 {
    FSEventsGetCurrentEventId()
  }

  /// The journal the folder's volume keeps its events in.
  static func volumeUUID(ofPath path: String) -> String? {
    var info = stat()
    guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else {
      return nil
    }
    return CFUUIDCreateString(nil, uuid) as String
  }
}
