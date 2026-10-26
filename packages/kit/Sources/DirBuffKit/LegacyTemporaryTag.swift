import Foundation

/// The Finder tag that versions before 0.2.0 put on each Temporary folder. DirBuff writes no tags
/// now: this is read and taken off once per folder, when the folder's Temporary setting moves into
/// the database (`Engine`).
enum LegacyTemporaryTag {
  static let name = "DirBuff: Temporary"

  /// Throws when the folder can't be read, so a folder that can't be reached stays pending rather
  /// than being read as untagged.
  static func isSet(on folder: URL) throws -> Bool {
    try tags(of: folder).contains(name)
  }

  static func remove(from folder: URL) throws {
    let tags = try tags(of: folder)
    guard tags.contains(name) else { return }
    try write(tags.filter { $0 != name }, to: folder)
  }

  /// Read through a fresh URL: one that already read the tags returns its cached values.
  private static func tags(of folder: URL) throws -> [String] {
    try URL(fileURLWithPath: folder.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
  }

  /// `URLResourceValues.tagNames` is read-only, so tags are written through `NSURL`.
  private static func write(_ tags: [String], to folder: URL) throws {
    try (URL(fileURLWithPath: folder.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
  }
}
