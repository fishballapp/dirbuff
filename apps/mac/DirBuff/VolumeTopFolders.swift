import AppKit
import DirBuffKit

/// Publishes the folders at the top of every volume but the startup disk, which the Finder
/// extension watches in place of the volume, and keeps the list current as volumes mount and
/// unmount and as folders come and go at the top of one. An actor, so listing a slow network
/// share never holds up the main thread.
actor VolumeTopFolders {
  private var topWatches: [any DispatchSourceFileSystemObject] = []

  /// Lives as long as the app, so the observers below hold it strongly.
  init() {
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
      NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: nil) {
        _ in Task { await self.publish() }
      }
    }
    Task { await publish() }
  }

  /// Reads the volumes afresh, so a run queued behind another still publishes the latest list.
  private func publish() {
    let volumes =
      (FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
      .filter { $0.path != "/" }
    for watch in topWatches { watch.cancel() }
    topWatches = volumes.compactMap(watchTop)
    let paths = System.topFolderPaths(of: volumes)
    guard let shared = FinderFolders.defaults, shared.volumeTopFolderPaths != paths else { return }
    shared.volumeTopFolderPaths = paths
  }

  /// `O_EVTONLY`, so the watch never stops the volume ejecting.
  private func watchTop(of volume: URL) -> (any DispatchSourceFileSystemObject)? {
    let descriptor = open(volume.path, O_EVTONLY)
    guard descriptor >= 0 else { return nil }
    let watch = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: .write)
    // Dispatch calls these on its own queue, off the actor.
    watch.setEventHandler { @Sendable in Task { await self.publish() } }
    watch.setCancelHandler { @Sendable in close(descriptor) }
    watch.resume()
    return watch
  }
}
