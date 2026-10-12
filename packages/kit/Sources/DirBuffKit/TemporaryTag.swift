import Foundation

/// The Finder tag that marks a Temporary folder. Removing it in Finder turns the folder back into a
/// plain folder.
public enum TemporaryTag {
  public static let name = "DirBuff: Temporary"

  public static func isSet(on folder: URL) -> Bool {
    (try? tags(of: folder).contains(name)) ?? false
  }

  public static func set(on folder: URL) throws {
    let tags = try tags(of: folder)
    guard !tags.contains(name) else { return }
    try write(tags + [name], to: folder)
  }

  public static func remove(from folder: URL) throws {
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
