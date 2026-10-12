import DirBuffCore
import Foundation

/// Facts about the Mac a run depends on.
public enum System {
  struct Capacity {
    var available: Int64
    var total: Int64
  }

  enum Failure: Error {
    case unknownCapacity(URL)
    case unknownBootTime(errno: Int32)
  }

  /// `volumeAvailableCapacityForImportantUsageKey` would read 0 on exFAT and FAT32, so the
  /// Automatic rule would clear every Temporary folder on a USB stick.
  static func capacity(of url: URL) throws -> Capacity {
    let values = try url.resourceValues(forKeys: [
      .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
    ])
    guard let available = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity
    else {
      throw Failure.unknownCapacity(url)
    }
    return Capacity(available: Int64(available), total: Int64(total))
  }

  static func bootTime() throws -> Date {
    var mib = [CTL_KERN, KERN_BOOTTIME]
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctl(&mib, u_int(mib.count), &boot, &size, nil, 0) == 0 else {
      throw Failure.unknownBootTime(errno: errno)
    }
    return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1e6)
  }

  public static func protectedFolderPaths(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    volumes: [URL] = FileManager.default.mountedVolumeURLs(
      includingResourceValuesForKeys: nil, options: []) ?? []
  ) -> [String] {
    Array(
      Set(protectedRoots(home: home, volumes: volumes).map { $0.resolvingSymlinksInPath().path })
    )
    .sorted()
  }

  public static func isProtected(
    _ folder: URL,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    volumes: [URL] = FileManager.default.mountedVolumeURLs(
      includingResourceValuesForKeys: nil, options: []) ?? []
  ) -> Bool {
    let resolved = folder.resolvingSymlinksInPath().path
    return protectedFolderPaths(home: home, volumes: volumes).contains(resolved)
  }
}
