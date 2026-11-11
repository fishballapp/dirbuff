import DirBuffCore
import Foundation
import os

/// The folder registry: adds, finds, relocates and removes the folders DirBuff knows. What each
/// buff does to a folder is the buff's (`BuffModule`).
public struct Engine: Sendable {
  public let store: Store
  private static let logger = Logger(subsystem: "app.fishball.dirbuff", category: "engine")

  public init(store: Store) {
    self.store = store
  }

  public enum Failure: Error, Equatable {
    case folderNotFound(id: Int64)
    /// A folder DirBuff never clears (`protectedRoots`), so a missing folder isn't located there.
    case protectedFolder
    /// The folder was deleted, moved to another disk, or moved to the Bin. Nothing acts on it until
    /// the user locates it.
    case folderMissing
    /// Locating a missing folder at one DirBuff already has would make two rules for one folder.
    case folderAlreadyAdded
    /// The folder chosen to locate a missing one is in the Bin.
    case folderInBin
  }

  /// Adds a folder to DirBuff, wearing nothing. A protected folder can be added too; Temporary
  /// refuses it. If already added, returns the existing record.
  public func add(_ folder: URL, now: Date = Date()) throws -> Folder {
    let canonical = try canonicalPath(of: folder)
    if let existing = try store.folder(path: canonical) {
      return existing
    }
    return try store.insert(
      Folder(
        bookmark: try folder.bookmarkData(),
        path: canonical,
        createdAt: now
      ))
  }

  /// Forgets the folder and its journal. The folder's files are left alone.
  public func remove(_ folder: Folder) throws {
    try store.deleteFolder(id: try require(folder.id))
  }

  /// Points a missing folder at where the user found it. Refuses one in the Bin, which would
  /// still be missing, and a protected folder for one that wears Temporary, which never clears
  /// there; Backup only copies, so a folder wearing nothing else may be Home or a drive's top.
  public func relocate(folderID: Int64, to url: URL) throws {
    guard var folder = try store.folder(id: folderID) else {
      throw Failure.folderNotFound(id: folderID)
    }
    if try store.temporaryWear(folderID: folderID) != nil, System.isProtected(url) {
      throw Failure.protectedFolder
    }
    let path = try canonicalPath(of: url)
    guard !Self.isInBin(path) else { throw Failure.folderInBin }
    guard try store.folder(path: path).map({ $0.id == folderID }) ?? true else {
      throw Failure.folderAlreadyAdded
    }
    folder.path = path
    folder.bookmark = try url.bookmarkData()
    folder.missingSince = nil
    try store.save(folder)
  }

  /// Reads the folder from the database and resolves its bookmark, recording where the folder now
  /// is if it moved. Throws when the folder can't be found or reached. A folder still owing its
  /// legacy tag's removal takes that first, so nothing acts on a folder before its Temporary
  /// setting is in the database.
  public func locate(folderID: Int64) throws -> LocatedFolder {
    guard var folder = try store.folder(id: folderID) else {
      throw Failure.folderNotFound(id: folderID)
    }
    var isStale = false
    let url: URL
    do {
      url = try URL(resolvingBookmarkData: folder.bookmark, bookmarkDataIsStale: &isStale)
    } catch {
      // An unplugged drive can't be resolved either; it isn't missing, just away.
      guard Self.isOnConnectedVolume(folder.path) else { throw error }
      throw Failure.folderMissing
    }
    // macOS tracks a folder moved to the Bin; following it there would clean inside the Bin.
    guard !Self.isInBin(url.path) else { throw Failure.folderMissing }
    // Once a folder has gone missing, a stale bookmark that resolves to its old path means macOS
    // fell back to the path: a new folder made there, not this one. It stays missing until the
    // user locates it. A folder put back from the Bin resolves by its identity, so it isn't stale.
    // ponytail: a folder renamed and replaced at its old path before DirBuff noticed it missing is
    // still followed to the new one. Rare; un-park if a user reports a rule on the wrong folder.
    guard !(isStale && url.path == folder.path && folder.missingSince != nil) else {
      throw Failure.folderMissing
    }
    if isStale || url.path != folder.path {
      folder.path = url.path
      folder.bookmark = try url.bookmarkData()
      try store.save(folder)
    }
    if try store.hasLegacyTag(folderID: folderID) {
      try takeOffLegacyTag(folderID: folderID, at: url)
    }
    return LocatedFolder(folder: folder, url: url)
  }

  /// Sets the folder's Temporary from its legacy tag, then takes the tag off. The setting is written
  /// first: a crash between the two leaves a tag nothing reads, where the other order could lose
  /// the setting. A folder that can't be read throws and stays pending.
  private func takeOffLegacyTag(folderID: Int64, at url: URL) throws {
    let hadTag = try LegacyTemporaryTag.isSet(on: url)
    guard try store.finishLegacyTag(folderID: folderID, hadTag: hadTag) else { return }
    do {
      try LegacyTemporaryTag.remove(from: url)
    } catch {
      // ponytail: if removing the tag fails, it stays on the folder, where Finder shows it, but
      // nothing reads it. Un-park if a user reports the tag still showing.
      Self.logger.error(
        "Couldn't take the old tag off \(url.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}

extension Engine {
  /// Whether a path is in a Bin: the user's (`~/.Trash`) or a drive's (`/Volumes/X/.Trashes`).
  static func isInBin(_ path: String) -> Bool {
    path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
  }

  /// Whether a path's drive is connected: always for a path on the startup disk.
  static func isOnConnectedVolume(_ path: String) -> Bool {
    let parts = path.split(separator: "/")
    guard parts.count >= 2, parts[0] == "Volumes" else { return true }
    return FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])")
  }
}

/// The path the bookmark resolves to: `/private/var/…` where the folder was given as `/var/…`.
public func canonicalPath(of url: URL) throws -> String {
  try url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath ?? url.path
}
