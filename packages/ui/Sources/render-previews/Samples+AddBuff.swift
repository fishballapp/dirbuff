import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation

/// A shelf for dragging Temporary onto: Downloads wears it, Scratch wears only Backup, and the
/// user's Library, protected, wears only Backup. Every folder on the shelf wears a buff, so Temporary
/// lights a tile only once Backup ships; Scratch and Library show that shelf.
extension Samples {
  /// Real home directory, so the folders draw their real Finder icons.
  private static let addBuffHome = NSHomeDirectory()

  /// `folder` as one called `name` that wears only Backup.
  private static func backupTile(_ id: Int64, _ name: String, from folder: FolderState)
    -> FolderState
  {
    var tile = folder
    tile.id = id
    tile.name = name
    tile.path = "\(addBuffHome)/\(name)"
    tile.location = "~/\(name)"
    tile.buffs = tile.buffs.map { row in
      var backup = row
      backup.buff = .backup
      backup.status = "Backed up 2 min ago"
      backup.setting = "Every version, thinning with age"
      return backup
    }
    return tile
  }

  static let addBuffShelf = {
    let downloads = "\(addBuffHome)/Downloads"
    var shelf = MainState(
      reports: [
        FolderReport(
          folder: Folder(
            id: 1, bookmark: Data(), path: downloads,
            settings: TemporarySettings(maxAgeDays: 14), wearsTemporary: true,
            createdAt: now.addingTimeInterval(-60 * 86_400), lastRunAt: now),
          reading: .success(
            Engine.FolderStatus(
              url: URL(fileURLWithPath: downloads), wearsTemporary: true,
              isProtectedRoot: false, items: [], dueNow: [], upcoming: [])))
      ],
      licence: .licensed,
      now: shownAt,
      binName: binName,
      home: addBuffHome,
      startupVolumeName: "Macintosh HD")
    guard let wearing = shelf.shelfFolders.first else { fail("no Downloads on the sample shelf") }
    shelf.shelfFolders += [
      backupTile(2, "Scratch", from: wearing), backupTile(3, "Library", from: wearing),
    ]
    return shelf
  }()

  static func addBuffFolder(_ name: String) -> FolderState {
    guard let folder = addBuffShelf.shelfFolders.first(where: { $0.name == name }) else {
      fail("no \(name) on the + Buff sample shelf")
    }
    return folder
  }
}
