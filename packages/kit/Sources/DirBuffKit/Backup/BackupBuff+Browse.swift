import Foundation

/// Browsing a folder's backups as Finder's column view shows a folder: the backups kept, then one
/// folder of one backup at a time, never a whole snapshot, so it costs the same for a folder of
/// ten files and a home folder of a million.
extension BackupBuff {
  /// The folder's backups, newest first. From the database when it knows which the repository
  /// holds; otherwise asked of the repository, which also makes that list.
  public func keptBackups(folderID: Int64, password: String? = nil) async throws -> [KeptBackup] {
    if try !store.isSnapshotListingPending() {
      return try store.keptBackups(folderID: folderID).reversed()
    }
    return try await commands.run {
      guard let record = try store.backupRecord(folderID: folderID) else { return [] }
      let session = try await session(password: password)
      return try await restic(session) { try await $0.snapshots(tags: [record.resticTag]) }
        .sorted { $0.time > $1.time }
        .map(KeptBackup.init)
    }
  }

  /// What the folder at `path` (inside the backed-up folder; `""` is its top) held in `backup`,
  /// one level, by name as Finder sorts them. Each says whether it has changed or gone on this
  /// Mac since: from the database's versions and one read of the folder as it is now, never a
  /// second listing. A backup with a password this Mac's Keychain doesn't open needs `password`.
  public func items(
    in path: String, of backup: KeptBackup, folderID: Int64, password: String? = nil
  ) async throws -> [BackupItem] {
    let nodes = try await commands.run {
      let session = try await session(password: password)
      do {
        return try await restic(session) {
          try await $0.tree(snapshot: backup.id, path: path.isEmpty ? "/" : "/" + path)
        }
      } catch ResticFailure.exited(.failed, let message) where message.hasSuffix(": not found") {
        throw Failure.notInBackup(path)
      }
    }
    // A folder that isn't on this Mac now (deleted, in the Bin, on a disk that isn't connected)
    // still has its backups to browse: nothing is marked.
    let local =
      (try? engine.locate(folderID: folderID).url).map {
        Self.localEntries(of: path.isEmpty ? $0 : $0.appendingPathComponent(path))
      } ?? .unreadable
    let changed = try store.backupNamesChanged(folderID: folderID, in: path, after: backup)
    return Self.items(nodes, in: path, savedAt: backup.savedAt, local: local, changed: changed)
  }

  /// Whether `password` opens this Mac's backup: throws `passwordDoesNotOpen` if not, so a page
  /// asking for it can say so whatever wanted it. Opening it with that password also finishes
  /// what opening the repository owes (a listing of the snapshots it holds).
  public func checkPassword(_ password: String) async throws {
    try await commands.run {
      let session = try await session(password: password)
      _ = try await restic(session) { try await $0.keys() }
    }
  }

  /// Whether the backed-up folder is on this Mac now: not deleted, in the Bin or on a disk that
  /// isn't connected. Without it, its backups are still there to browse, but an item has no place
  /// to go back to.
  public func isFolderOnThisMac(folderID: Int64) -> Bool {
    (try? engine.locate(folderID: folderID)) != nil
  }

  /// A file's versions across the backups, from the database alone, so it shows offline.
  public func history(of path: String, folderID: Int64) throws -> FileHistory {
    try store.backupFileHistory(folderID: folderID, path: path)
  }

  /// The Mac's repository, opened with `password` when one is given instead of the Keychain's,
  /// from the first step: finishing a change cut short and listing the snapshots use it too.
  func session(password: String?, now: Date = Date()) async throws -> Session {
    try await openRepository(now: now, password: password)
  }

  /// The backup's listing, marked against the folder as it is now, by name as Finder sorts.
  static func items(
    _ nodes: [TreeNode], in path: String, savedAt: Date, local: LocalFolder, changed: Set<String>
  ) -> [BackupItem] {
    nodes
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      .compactMap { node -> BackupItem? in
        let kind: BackupItem.Kind
        switch node.type {
        case "file": kind = .file
        case "dir": kind = .folder
        case "symlink": kind = .link
        // Devices, sockets and pipes: nothing a person restores.
        default: return nil
        }
        let sinceThen: BackupItem.SinceThen?
        switch local {
        case .missing: sinceThen = .deleted
        case .unreadable: sinceThen = .unknown
        case .entries(let entries):
          if let now = entries[node.name] {
            sinceThen =
              changed.contains(node.name)
                || now.kind != kind
                || (kind == .file && (now.size != node.size || now.modified > savedAt))
              ? .changed : nil
          } else {
            sinceThen = .deleted
          }
        }
        return BackupItem(
          path: path.isEmpty ? node.name : path + "/" + node.name, kind: kind,
          size: kind == .file ? node.size : nil, sinceThen: sinceThen)
      }
  }

  /// What a folder on this Mac holds now, in one read of it, whatever it holds. Only a folder
  /// that isn't there is missing: one DirBuff may not read (macOS's privacy refusal, a folder's
  /// permissions) tells nothing of what it holds.
  static func localEntries(of folder: URL) -> LocalFolder {
    let keys: [URLResourceKey] = [
      .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
    ]
    let urls: [URL]
    do {
      urls = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: keys)
    } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile
      || (error.underlying as? POSIXError)?.code == .ENOTDIR
    {
      return .missing
    } catch {
      return .unreadable
    }
    let isCaseSensitive =
      (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
      .volumeSupportsCaseSensitiveNames ?? true
    var entries = LocalNames(isCaseSensitive: isCaseSensitive)
    for url in urls {
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
      let kind: BackupItem.Kind =
        values.isSymbolicLink == true ? .link : values.isDirectory == true ? .folder : .file
      entries[url.lastPathComponent] = LocalEntry(
        kind: kind, size: values.fileSize.map(Int64.init),
        modified: values.contentModificationDate ?? .distantPast)
    }
    return .entries(entries)
  }

  enum LocalFolder: Equatable {
    /// Nothing is there: everything the backup holds in it has gone.
    case missing
    /// It is there but can't be read.
    case unreadable
    case entries(LocalNames)
  }

  /// A folder's items by name, matched as its volume matches names: on a case-insensitive one,
  /// "Report.pdf" is the "report.pdf" there, which a restore can't sit beside under that name.
  struct LocalNames: Equatable {
    let isCaseSensitive: Bool
    private var byName: [String: LocalEntry] = [:]

    init(isCaseSensitive: Bool) {
      self.isCaseSensitive = isCaseSensitive
    }

    subscript(name: String) -> LocalEntry? {
      get { byName[key(name)] }
      set { byName[key(name)] = newValue }
    }

    private func key(_ name: String) -> String {
      isCaseSensitive ? name : name.folding(options: .caseInsensitive, locale: nil)
    }
  }

  struct LocalEntry: Equatable {
    var kind: BackupItem.Kind
    var size: Int64?
    var modified: Date
  }
}

/// A file or folder in one of a folder's backups.
public struct BackupItem: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable {
    case file, folder, link
  }

  /// What became of it on this Mac after that backup.
  public enum SinceThen: Sendable, Hashable {
    /// The folder on this Mac has nothing of that name now.
    case deleted
    /// It is there, but not as that backup saved it (for a folder: something in it changed).
    case changed
    /// The folder it is in on this Mac can't be read, so what became of it isn't known.
    case unknown
  }

  /// Inside the backed-up folder, `a/b.txt`.
  public var path: String
  public var kind: Kind
  /// A file's size; nil for a folder or a link.
  public var size: Int64?
  /// Nil when it is on this Mac as that backup saved it, as far as DirBuff can tell.
  public var sinceThen: SinceThen?

  public init(path: String, kind: Kind, size: Int64? = nil, sinceThen: SinceThen? = nil) {
    self.path = path
    self.kind = kind
    self.size = size
    self.sinceThen = sinceThen
  }

  public var id: String { path }
  public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
  /// The folder it is in, inside the backed-up folder; `""` at the top.
  public var parent: String { path.split(separator: "/").dropLast().joined(separator: "/") }
  public var isFolder: Bool { kind == .folder }
}
