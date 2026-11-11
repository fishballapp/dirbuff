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

  /// Visits every entry under `folder` (a link is listed, never followed, as restic does) except
  /// inside what is left out, found, or a `CACHEDIR.TAG` folder.
  static func walk(
    _ folder: String, skippingNames names: Set<String>, skippingPaths paths: Set<String>
  ) -> (timeMachineExcluded: [String], cloudOnly: [String]) {
    var timeMachineExcluded: [String] = []
    var cloudOnly: [String] = []
    var pending = [folder]
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: listingSize, alignment: 8)
    defer { buffer.deallocate() }
    while let directory = pending.popLast() {
      for entry in entries(in: directory, buffer: buffer) {
        let path = { "\(directory)/\(entry.name)" }
        if entry.isFolder, names.contains(entry.name) || paths.contains(path()) || isCache(path()) {
          continue
        }
        if entry.isCloudOnly {
          cloudOnly.append(path())
        } else if entry.mayHaveExtendedAttributes && hasTimeMachineExclusion(path()) {
          timeMachineExcluded.append(path())
        } else if entry.isFolder {
          pending.append(path())
        }
      }
    }
    return (timeMachineExcluded, cloudOnly)
  }

  /// Whether `path` itself (a link is not followed) carries Time Machine's attribute.
  ///
  /// It lists the names instead of asking for one: on APFS that is several times cheaper for an
  /// entry that lacks the attribute, which most do, and the length alone rules out an entry
  /// whose attributes are too short to include it.
  static func hasTimeMachineExclusion(_ path: String) -> Bool {
    let attribute = BackupDefaults.timeMachineExclusionAttribute
    let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
    guard size > attribute.utf8.count else { return false }
    var names = [CChar](repeating: 0, count: size)
    let length = listxattr(path, &names, size, XATTR_NOFOLLOW)
    guard length > 0 else { return false }
    return String(decoding: names.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
      .split(separator: "\0").contains(Substring(attribute))
  }

  /// What a folder's listing says about one entry: all the walk needs to know without a call of
  /// its own for each.
  struct Entry: Equatable {
    var name: String
    var isFolder: Bool
    /// The BSD flags (`st_flags`).
    var flags: UInt32
    /// `nil` when the volume doesn't report them.
    var extendedFlags: UInt32? = nil

    /// Only in iCloud: reading it would download it.
    var isCloudOnly: Bool { flags & UInt32(SF_DATALESS) != 0 }

    /// Whether to ask for the entry's attributes: not when the volume says it has none.
    var mayHaveExtendedAttributes: Bool { (extendedFlags ?? 0) & UInt32(EF_NO_XATTRS) == 0 }
  }

  static let listingSize = 128 * 1024

  /// The entries of `directory`: name, type, flags and extended flags together, one call for each
  /// `listingSize` of them. What can't be read is left out, as `fts` does.
  static func entries(in directory: String, buffer: UnsafeMutableRawPointer) -> [Entry] {
    let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return [] }
    defer { close(descriptor) }
    var request = attrlist()
    request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    request.commonattr =
      ATTR_CMN_RETURNED_ATTRS | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_FLAGS)
    request.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
    var entries: [Entry] = []
    while true {
      let count = getattrlistbulk(
        descriptor, &request, buffer, listingSize, UInt64(FSOPT_ATTR_CMN_EXTENDED))
      guard count > 0 else { return entries }
      var record = UnsafeRawPointer(buffer)
      for _ in 0..<count {
        if let entry = entry(at: record, in: directory) { entries.append(entry) }
        record += Int(record.loadUnaligned(as: UInt32.self))
      }
    }
  }

  /// One record of a listing: its length, the attributes it carries, then each of them in the
  /// order of the request. A volume that leaves out the type or the flags gets a `lstat` instead.
  static func entry(at record: UnsafeRawPointer, in directory: String) -> Entry? {
    var field = record + MemoryLayout<UInt32>.size
    let returned = field.loadUnaligned(as: attribute_set_t.self)
    field += MemoryLayout<attribute_set_t>.size
    let nameReferenceStart = field
    func next<Value>(_ attribute: Int32, of group: attrgroup_t) -> Value? {
      guard group & attrgroup_t(attribute) != 0 else { return nil }
      defer { field += MemoryLayout<Value>.size }
      return field.loadUnaligned(as: Value.self)
    }
    guard let nameReference: attrreference_t = next(ATTR_CMN_NAME, of: returned.commonattr)
    else { return nil }
    let name = String(
      cString: (nameReferenceStart + Int(nameReference.attr_dataoffset))
        .assumingMemoryBound(to: CChar.self))
    let type: fsobj_type_t? = next(ATTR_CMN_OBJTYPE, of: returned.commonattr)
    let flags: UInt32? = next(ATTR_CMN_FLAGS, of: returned.commonattr)
    let extendedFlags: UInt32? = next(ATTR_CMNEXT_EXT_FLAGS, of: returned.forkattr)
    if let type, let flags {
      return Entry(
        name: name, isFolder: type == UInt32(VDIR.rawValue), flags: flags,
        extendedFlags: extendedFlags)
    }
    var status = stat()
    guard lstat("\(directory)/\(name)", &status) == 0 else { return nil }
    return Entry(
      name: name, isFolder: status.st_mode & S_IFMT == S_IFDIR, flags: status.st_flags,
      extendedFlags: extendedFlags)
  }

  /// Whether the folder holds a `CACHEDIR.TAG` that begins with the signature. A tag that's only in
  /// iCloud isn't read, which would download it.
  static func isCache(_ folder: UnsafePointer<CChar>) -> Bool {
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
