import DirBuffKit
import Foundation

/// The system notification for a cause that needs the user's Backup:
/// one per cause, and one per day while the cause lasts (`Store.wasNotified`). A cause every
/// folder shares (the Google account, Drive full) is one notification naming the folders; a
/// folder's own (files it couldn't read, failing runs) is one for that folder.
public struct BackupNotification: Sendable, Equatable, Identifiable {
  /// What the day's record is kept under: the fix, and the folder when the cause is its own.
  public var cause: String
  /// "Can't back up Documents", "Can't back up Documents and 2 more".
  public var title: String
  /// Why, as the row says it: "Signed out of Google Drive".
  public var body: String
  /// The folder the notification opens: the first it names.
  public var folderID: Int64

  public var id: String { cause }

  /// The notifications for every Backup row that needs the user, in the folders' order.
  public static func all(_ folders: [FolderState]) -> [BackupNotification] {
    var found: [(notification: BackupNotification, others: Int)] = []
    for folder in folders {
      for row in folder.buffs where row.buff == .backup {
        guard case .needsYou(let fix) = row.state else { continue }
        let cause =
          fix.isSharedByFolders ? "backup.\(fix.cause)" : "backup.\(fix.cause).\(folder.id)"
        if let index = found.firstIndex(where: { $0.notification.cause == cause }) {
          found[index].others += 1
          continue
        }
        found.append(
          (
            BackupNotification(
              cause: cause, title: "Can't back up \(folder.name)",
              // "Can't find" names no folder of its own: the row draws it as a pill.
              body: fix == .locate ? "\(row.status) \(folder.name)" : row.status,
              folderID: folder.id),
            0
          ))
      }
    }
    return found.map { notification, others in
      var notification = notification
      if others > 0 { notification.title += " and \(others) more" }
      return notification
    }
  }
}

extension Fix {
  /// Names the cause the fix clears, for the day's record.
  fileprivate var cause: String {
    switch self {
    case .giveAccess: "giveAccess"
    case .locate: "locate"
    case .signInAgain: "signInAgain"
    case .chooseAccount: "chooseAccount"
    case .makeRoom: "makeRoom"
    case .showFiles: "showFiles"
    case .backUpNow: "backUpNow"
    case .putBackFromDriveBin: "putBackFromDriveBin"
    case .startAgain: "startAgain"
    case .showDetails: "showDetails"
    }
  }
}
