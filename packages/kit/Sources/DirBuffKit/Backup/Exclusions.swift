import Darwin
import DirBuffCore

/// What a backup of one folder leaves out, as patterns for restic's exclude file (with
/// `--exclude-caches`, which leaves out `CACHEDIR.TAG` folders itself).
///
/// restic can't see an extended attribute or a file that's only in iCloud, so a walk of the folder
/// finds those first: what Time Machine is told to skip, and what reading would download. The walk
/// doesn't go into what's left out anyway.
struct Exclusions: Equatable {
  var patterns: [String]
  /// Files and folders left out because they are only in iCloud.
  var cloudOnlyCount: Int

  /// `folder`, `home` and `own` (DirBuff's own folders, left out wherever they are) are canonical
  /// paths, as restic sees them.
  static func scan(_ folder: String, leftOut: [LeaveOut], home: String, own: [String])
    -> Exclusions
  {
    let names = Set(
      BackupDefaults.leftOutNames
        + leftOut.compactMap { item in if case .name(let name) = item { name } else { nil } })
    let paths = Set(
      leftOut.compactMap { item in
        if case .path(let path) = item { "\(folder)/\(path)" } else { nil }
      }
        + ([home + "/Library"] + own).filter { $0.hasPrefix(folder + "/") })
    let found = walk(folder, skippingNames: names, skippingPaths: paths)
    return Exclusions(
      patterns: names.sorted().map(escaped)
        + (paths.union(found.timeMachineExcluded).union(found.cloudOnly)).sorted().map(escaped),
      cloudOnlyCount: found.cloudOnly.count)
  }

  /// A name or an absolute path as a pattern that matches only itself: restic reads `*`, `?`, `[`
  /// and `\` as a glob, `$` as a variable, and a line starting with `#` as a comment.
  static func escaped(_ text: String) -> String {
    let escaped = text.reduce(into: "") { escaped, character in
      switch character {
      case "*", "?", "[", "]", "\\": escaped += "\\\(character)"
      case "$": escaped += "$$"
      default: escaped.append(character)
      }
    }
    return escaped.hasPrefix("#") ? "\\" + escaped : escaped
  }

  private static func walk(
    _ folder: String, skippingNames names: Set<String>, skippingPaths paths: Set<String>
  ) -> (timeMachineExcluded: [String], cloudOnly: [String]) {
    var timeMachineExcluded: [String] = []
    var cloudOnly: [String] = []
    let root = strdup(folder)
    defer { free(root) }
    // Physical: a link is listed, never followed, as restic does.
    guard let stream = fts_open([root, nil], FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
      return ([], [])
    }
    defer { fts_close(stream) }
    while let entry = fts_read(stream) {
      let info = Int32(entry.pointee.fts_info)
      // The folder itself, a folder on the way out, and what couldn't be read: restic names those.
      guard entry.pointee.fts_level > 0,
        [FTS_D, FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT].contains(info),
        let accessPath = entry.pointee.fts_accpath
      else { continue }
      let isFolder = info == FTS_D
      let path = { String(cString: entry.pointee.fts_path) }
      if isFolder {
        let path = path()
        if names.contains(lastComponent(of: path)) || paths.contains(path)
          || isCache(accessPath)
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

  private static func lastComponent(of path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }

  /// Whether the folder holds a `CACHEDIR.TAG` that begins with the signature. A tag that's only in
  /// iCloud isn't read, which would download it.
  private static func isCache(_ folder: UnsafePointer<CChar>) -> Bool {
    let tag = String(cString: folder) + "/" + BackupDefaults.cacheDirectoryTag
    var status = stat()
    guard lstat(tag, &status) == 0, status.st_flags & UInt32(SF_DATALESS) == 0 else {
      return false
    }
    let descriptor = open(tag, O_RDONLY)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    let signature = Array(BackupDefaults.cacheDirectorySignature.utf8)
    var start = [UInt8](repeating: 0, count: signature.count)
    return read(descriptor, &start, start.count) == start.count && start == signature
  }
}
