import Foundation

/// A top-level entry of a Temporary folder: a file, a package or a whole subfolder.
public struct Item: Sendable, Hashable {
  public var url: URL
  /// When the item last arrived or changed; nil when neither date is known.
  public var freshness: Date?
  /// Bytes on disk, everything inside included.
  public var size: Int64

  public init(url: URL, freshness: Date?, size: Int64) {
    self.url = url
    self.freshness = freshness
    self.size = size
  }
}

/// The later of date added and date modified: dropping a file in, or editing it,
/// restarts its clock.
public func freshness(added: Date?, modified: Date?) -> Date? {
  [added, modified].compactMap(\.self).max()
}
