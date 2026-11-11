import AppKit
import DirBuffCore

/// A system alert Backup asks with: its words, its buttons (the first is the default) and an
/// optional checkbox. The app runs it as an `NSAlert`; previews draw the same alert.
public struct BackupAlert: Sendable, Equatable {
  public var title: String
  public var message: String
  public var buttons: [String]
  /// A checkbox under the message, off to begin with.
  public var checkbox: String?

  /// **Start Again…**: the backup in Drive is gone, and a new one starts without its history.
  public static let startAgain = BackupAlert(
    title: "Start a new backup in Google Drive?",
    message:
      "The old backup was deleted from your Drive, so its versions are lost and can't be restored. DirBuff starts a new backup from what is on this Mac now.",
    buttons: ["Start Again", "Cancel"])

  /// Backup put on a folder from outside the window (a `dirbuff://` URL, Finder's menu): any app
  /// or web page can open the URL, so nothing goes to Drive before the user says so.
  public static func addBackup(folderName name: String) -> BackupAlert {
    BackupAlert(
      title: "Back up \(name) to Google Drive?",
      message:
        "Every file in \(name) goes to your Google Drive, with every version kept. You can take Backup off at any time.",
      buttons: ["Back Up", "Cancel"])
  }

  /// **Start a New Backup Here…**, signed in to another account than the backup's: a new backup
  /// in this account's Drive becomes this Mac's, and the old one is left where it is.
  public static func startNewBackup(owner: String, signedIn: String) -> BackupAlert {
    BackupAlert(
      title: "Start a new backup in \(signedIn)’s Drive?",
      message:
        "This Mac's backup stays in \(owner)’s Drive, but DirBuff stops using it, so its versions can't be restored from here. Every Backup folder backs up again from the start.",
      buttons: ["Start New Backup", "Cancel"])
  }

  /// A shorter history, chosen in the card's pop-up or by Undo: the versions it drops are
  /// deleted from Drive. The card asks with SwiftUI's alert in these words.
  public static func shorterHistory(_ history: BackupHistory, folderName: String) -> BackupAlert {
    let words = ShorterHistoryWords(history: history, folderName: folderName)
    return BackupAlert(
      title: words.title, message: words.message, buttons: [words.button, "Cancel"])
  }

  /// **Take Off** for Backup, with the box that deletes its backup from Drive too.
  public static func takeOff(folderName name: String) -> BackupAlert {
    BackupAlert(
      title: "Take Backup off \(name)?",
      message:
        "New changes stop going to Google Drive. Nothing on this Mac changes, and the files already in Drive stay there. Its settings will be forgotten.",
      buttons: ["Take Off", "Cancel"],
      checkbox:
        "Also delete this folder's backup from Google Drive. Its versions can't be brought back.")
  }

  /// The alert, ready to run.
  @MainActor
  public func makeAlert() -> NSAlert {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    for button in buttons { alert.addButton(withTitle: button) }
    if let checkbox {
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = checkbox
      alert.suppressionButton?.state = .off
    }
    return alert
  }
}
