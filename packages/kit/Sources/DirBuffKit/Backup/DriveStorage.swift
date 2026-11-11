import Foundation

/// The Macs' backups in the user's Google Drive, each restic repository reached through a
/// `DriveBridge`:
///
/// ```
/// My Drive/DirBuff Backup/   README.txt, and a folder per Mac
///   <Mac name>/              one restic repository
/// ```
///
/// The two folders' Drive IDs are kept once found or made, so moving or renaming either in Drive
/// changes nothing.
public struct DriveStorage: BackupStorage {
  public static let folderName = "DirBuff Backup"
  public static let readmeName = "README.txt"

  public let drive: any DriveFiles
  public let store: Store
  /// What a new repository's folder is called: the computer's name.
  public let macName: String
  private let makeBridge: @Sendable (DriveFileID) -> DriveBridge

  public init(drive: any DriveFiles, store: Store, macName: String) {
    self.init(
      drive: drive, store: store, macName: macName,
      makeBridge: { DriveBridge(drive: drive, store: store, repository: $0) })
  }

  init(
    drive: any DriveFiles, store: Store, macName: String,
    makeBridge: @escaping @Sendable (DriveFileID) -> DriveBridge
  ) {
    self.drive = drive
    self.store = store
    self.macName = macName
    self.makeBridge = makeBridge
  }

  // MARK: BackupStorage

  /// A new repository gets a folder of its own, never another Mac's of the same name: that one
  /// is taken over only by `adopt`.
  public func thisMac() async throws -> any BackupRepository {
    if let id = try store.backupDriveFolders().repository {
      return DriveRepository(bridge: makeBridge(id))
    }
    let backups = try await backupsFolder()
    let taken = Set(try await drive.allChildren(of: backups).map(\.name))
    var name = macName
    var number = 1
    while taken.contains(name) {
      number += 1
      name = "\(macName) (\(number))"
    }
    let folder = try await drive.createFolder(named: name, in: backups)
    try store.saveBackupDriveRepository(folder.id)
    return DriveRepository(bridge: makeBridge(folder.id))
  }

  public func macs() async throws -> [BackedUpMac] {
    guard let backups = try await existingBackupsFolder() else { return [] }
    let thisMac = try store.backupDriveFolders().repository
    var macs: [BackedUpMac] = []
    for folder in try await drive.allChildren(of: backups) where folder.isFolder {
      let isRepository = try await drive.allChildren(of: folder.id).contains {
        !$0.isFolder && $0.name == RepositoryLayout.config
      }
      guard isRepository else { continue }
      macs.append(
        BackedUpMac(id: folder.id.rawValue, name: folder.name, isThisMac: folder.id == thisMac))
    }
    return macs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Another Mac's repository is listed afresh: the bridge's table knows only what this Mac
  /// wrote.
  public func repository(of mac: BackedUpMac) async throws -> any BackupRepository {
    let id = DriveFileID(mac.id)
    if id == (try store.backupDriveFolders().repository) { return try await thisMac() }
    let bridge = makeBridge(id)
    try await bridge.rebuildTable()
    return DriveRepository(bridge: bridge)
  }

  // MARK: DirBuff Backup

  /// The kept folder, or one this app made in an earlier life (on another Mac, or before the
  /// database was lost), kept from now on. Every Mac's backups go in the one folder.
  private func existingBackupsFolder() async throws -> DriveFileID? {
    if let id = try store.backupDriveFolders().backups { return id }
    let items = try await drive.allCreated()
    let ours = Set(items.map(\.id))
    let childCounts = Dictionary(grouping: items.compactMap(\.parents.first), by: { $0 })
      .mapValues(\.count)
    // Two Macs that both made one: the one holding more is the one to use.
    guard
      let found = items.filter({
        $0.isFolder && $0.name == Self.folderName && !$0.parents.contains(where: ours.contains)
      }).max(by: { childCounts[$0.id, default: 0] < childCounts[$1.id, default: 0] })
    else { return nil }
    let hasReadme = items.contains {
      $0.parents.contains(found.id) && $0.name == Self.readmeName && !$0.isFolder
    }
    if !hasReadme { try await writeReadme(in: found.id) }
    try store.saveBackupDriveFolder(found.id)
    return found.id
  }

  private func backupsFolder() async throws -> DriveFileID {
    if let existing = try await existingBackupsFolder() { return existing }
    let folder = try await drive.createFolder(named: Self.folderName, in: nil).id
    try await writeReadme(in: folder)
    try store.saveBackupDriveFolder(folder)
    return folder
  }

  private func writeReadme(in folder: DriveFileID) async throws {
    _ = try await drive.upload(Data(BackupReadme.text.utf8), named: Self.readmeName, in: folder)
  }
}

/// One Mac's repository in Drive.
struct DriveRepository: BackupRepository {
  let bridge: DriveBridge

  func serving<Result>(_ restic: Restic, _ body: (Restic) async throws -> Result) async throws
    -> Result
  {
    try await bridge.serving(restic, body)
  }

  func refreshListing() async throws -> [String] {
    try await bridge.rebuildTable()
  }
}
