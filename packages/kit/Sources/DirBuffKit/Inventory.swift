import DirBuffCore
import Foundation

/// Lists a folder's items from file metadata alone: it never reads a file's contents, so it never
/// downloads an evicted iCloud file.
public enum Inventory {
  private static let keys: [URLResourceKey] = [
    .isDirectoryKey, .isPackageKey, .isHiddenKey, .addedToDirectoryDateKey,
    .contentModificationDateKey, .totalFileAllocatedSizeKey,
  ]

  /// Hidden entries (`.DS_Store`, AppleDouble `._` files, a custom icon) are neither listed nor
  /// dated, but their bytes count towards the item they sit in.
  public static func items(in folder: URL) throws -> [Item] {
    try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
      .compactMap(item(at:))
  }

  /// The item at `url` as it is now; nil for a hidden one.
  public static func item(at url: URL) throws -> Item? {
    let values = try url.resourceValues(forKeys: Set(keys))
    guard !isHidden(url, values) else { return nil }
    return isPlainDirectory(values) ? directory(url, values) : leaf(url, values)
  }

  /// A file, symlink or package (`.app`, `.photoslibrary`): judged by its own dates alone.
  private static func leaf(_ url: URL, _ values: URLResourceValues) -> Item {
    let packageContents = values.isPackage == true ? walk(url).size : 0
    return Item(
      url: url,
      freshness: freshness(
        added: values.addedToDirectoryDate, modified: values.contentModificationDate),
      size: size(values) + packageContents
    )
  }

  /// A subfolder: as fresh as the newest thing anywhere inside it. Undated when
  /// part of it can't be read, since what can't be seen may be fresh.
  private static func directory(_ url: URL, _ values: URLResourceValues) -> Item {
    let contents = walk(url)
    return Item(
      url: url,
      freshness: contents.isComplete
        ? [ownDate(values), contents.freshness].compactMap(\.self).max() : nil,
      size: size(values) + contents.size
    )
  }

  private static func walk(_ root: URL) -> (freshness: Date?, size: Int64, isComplete: Bool) {
    var isComplete = true
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: keys,
        errorHandler: { _, _ in
          isComplete = false
          return true
        })
    else { return (nil, 0, false) }

    var newest: Date?
    var size: Int64 = 0
    // Everything below a hidden folder or a package counts for size, not for dates. The walk is
    // depth-first, so the outermost such folder is the only one to remember.
    var undatedRoot: String?
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
        isComplete = false
        continue
      }
      size += Self.size(values)

      if let undated = undatedRoot, url.path.hasPrefix(undated + "/") { continue }
      undatedRoot = nil
      guard !isHidden(url, values) else {
        if values.isDirectory == true { undatedRoot = url.path }
        continue
      }
      if values.isPackage == true { undatedRoot = url.path }

      let date =
        isPlainDirectory(values)
        ? ownDate(values)
        : freshness(added: values.addedToDirectoryDate, modified: values.contentModificationDate)
      newest = [newest, date].compactMap(\.self).max()
    }
    return (newest, size, isComplete)
  }

  /// A folder's modified date moves whenever Finder writes `.DS_Store` into it, so it only stands
  /// in where there is no date added (exFAT, FAT32).
  private static func ownDate(_ values: URLResourceValues) -> Date? {
    values.addedToDirectoryDate ?? values.contentModificationDate
  }

  private static func isPlainDirectory(_ values: URLResourceValues) -> Bool {
    values.isDirectory == true && values.isPackage != true
  }

  private static func isHidden(_ url: URL, _ values: URLResourceValues) -> Bool {
    values.isHidden == true || url.lastPathComponent.hasPrefix(".")
  }

  private static func size(_ values: URLResourceValues) -> Int64 {
    Int64(values.totalFileAllocatedSize ?? 0)
  }
}
