import Foundation

/// Folders DirBuff never clears, however they are tagged. The caller compares them with symlinks
/// resolved on both sides: Documents may itself be a link to another drive.
public func protectedRoots(home: URL, volumes: [URL]) -> [URL] {
  ["/", "/Applications", "/Library", "/System", "/Users"].map { URL(fileURLWithPath: $0) }
    + [home] + ["Desktop", "Documents", "Library"].map { home.appendingPathComponent($0) }
    + volumes
}
