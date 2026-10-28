import Foundation

/// Folders DirBuff never clears, because clearing them would break the Mac rather than tidy it:
/// the system's folders, a drive's root, the home folder (whose top-level items are Desktop,
/// Documents and Library themselves) and its Library (every app's data). Any other folder, Desktop
/// and Documents included, is the user's to buff. The caller compares them with symlinks resolved
/// on both sides: Library may itself be a link to another drive.
public func protectedRoots(home: URL, volumes: [URL]) -> [URL] {
  ["/", "/Applications", "/Library", "/System", "/Users"].map { URL(fileURLWithPath: $0) }
    + [home, home.appendingPathComponent("Library")] + volumes
}
