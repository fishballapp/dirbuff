import Foundation

/// The Google sign-in sheet: asked for when Backup goes on while signed out, by Sign In Again…,
/// and from Settings › Backup. It says what DirBuff can see (only the files it creates in the
/// user's Drive), waits for the browser, then names the account before anything is backed up.
public struct GoogleSignInState: Sendable, Equatable, Identifiable {
  public enum Step: Sendable, Equatable {
    /// What signing in means, before the browser opens.
    case ask
    /// The browser is open, waiting for Google's answer.
    case waiting
    /// Signed in, to this account if Google said which.
    case signedIn(account: String?)
    /// Signed in as `signedIn`, but this Mac's backup is in `owner`'s Drive: nothing is backed up
    /// until the user signs in to that account, or starts a new backup in this one.
    case otherAccount(owner: String, signedIn: String?)
    /// Why signing in didn't work, in words.
    case failed(String)
  }

  /// Why the sheet asks.
  public enum Reason: Sendable, Equatable {
    /// Backup just went on a folder, by name and path, while signed out.
    case backUp(folderName: String, folderPath: String)
    /// Google stopped accepting DirBuff's access: Sign In Again….
    case signInAgain
    /// Settings › Backup's Sign In with Google….
    case settings
  }

  public let id = UUID()
  public var reason: Reason
  public var step: Step

  public init(reason: Reason, step: Step = .ask) {
    self.reason = reason
    self.step = step
  }

  /// The heading for the steps before the account is known.
  var title: String {
    if case .failed = step { return "Couldn't sign in to Google" }
    if case .otherAccount(let owner, _) = step { return "This Mac's backup is in \(owner)’s Drive" }
    return reason == .signInAgain
      ? "Sign in to Google Drive again" : "Backup goes to your Google Drive"
  }

  /// What signing in means: where the files go, and what DirBuff can see.
  var explanation: String {
    let sees = "DirBuff can see only the files it creates there, nothing else in your Drive."
    switch reason {
    case .backUp(let name, _):
      return
        "Sign in once. DirBuff keeps \(possessive(name)) files in a DirBuff Backup folder in your Google Drive. \(sees)"
    case .signInAgain:
      return
        "Google no longer accepts DirBuff's access, so nothing is backed up. Sign in with the same account to carry on. \(sees)"
    case .settings:
      return
        "DirBuff keeps your Backup folders' files in a DirBuff Backup folder in your Google Drive. \(sees)"
    }
  }

  /// The sentence under the heading, at each step.
  var detail: String {
    switch step {
    case .ask: explanation
    case .waiting:
      "Finish signing in in your browser. Google asks you to let DirBuff see the files it creates in your Drive."
    case .signedIn: signedInDetail
    case .otherAccount(let owner, let signedIn):
      "You signed in as \(signedIn ?? "another account"). DirBuff can see only the files it made in each account, so it can't reach the backup from here. Sign in to \(owner) to carry on, or start a new backup in this account; the old one stays where it is."
    case .failed(let message): message
    }
  }

  /// Under the account, once signed in.
  var signedInDetail: String {
    switch reason {
    case .backUp(let name, _):
      "Every version of \(possessive(name)) files goes to this account's Drive. If Drive fills up, DirBuff says so on the folder."
    case .signInAgain:
      "Backups carry on into the same backup in this account's Drive."
    case .settings:
      "Every Backup folder goes to this account's Drive."
    }
  }

  /// The button that ends the sheet once signed in.
  var confirmTitle: String {
    switch reason {
    case .backUp: "Start Backup"
    case .signInAgain: "Carry On"
    case .settings: "Done"
    }
  }
}

/// "Documents'", "Exports'": the name and an apostrophe, as the sheet says it.
func possessive(_ name: String) -> String {
  name.hasSuffix("s") ? "\(name)’" : "\(name)’s"
}
