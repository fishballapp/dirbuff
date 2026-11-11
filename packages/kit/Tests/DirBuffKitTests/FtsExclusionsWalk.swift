import Darwin
import DirBuffCore

@testable import DirBuffKit

/// The walk `Exclusions` made before it read a folder's attributes in bulk: `fts`, a `stat` for
/// every entry and a `getxattr` for each. It stays as the reference the bulk walk must agree with.
enum FtsExclusionsWalk {
  static func walk(
    _ folder: String, skippingNames names: Set<String>, skippingPaths paths: Set<String>
  ) -> (timeMachineExcluded: [String], cloudOnly: [String]) {
    var timeMachineExcluded: [String] = []
    var cloudOnly: [String] = []
    let root = strdup(folder)
    defer { free(root) }
    guard let stream = fts_open([root, nil], FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
      return ([], [])
    }
    defer { fts_close(stream) }
    while let entry = fts_read(stream) {
      let info = Int32(entry.pointee.fts_info)
      guard entry.pointee.fts_level > 0,
        [FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT].contains(info),
        let accessPath = entry.pointee.fts_accpath
      else { continue }
      let isFolder = info == FTS_D
      let path = { String(cString: entry.pointee.fts_path) }
      if isFolder {
        let path = path()
        if names.contains(String(path.split(separator: "/").last ?? "")) || paths.contains(path)
          || Exclusions.isCache(accessPath)
        {
          fts_set(stream, entry, FTS_SKIP)
          continue
        }
      }
      let isCloudOnly = entry.pointee.fts_statp.pointee.st_flags & UInt32(SF_DATALESS) != 0
      let isTimeMachineExcluded =
        getxattr(
          accessPath, BackupDefaults.timeMachineExclusionAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        >= 0
      guard isCloudOnly || isTimeMachineExcluded else { continue }
      if isCloudOnly {
        cloudOnly.append(path())
      } else {
        timeMachineExcluded.append(path())
      }
      if isFolder { fts_set(stream, entry, FTS_SKIP) }
    }
    return (timeMachineExcluded, cloudOnly)
  }
}
