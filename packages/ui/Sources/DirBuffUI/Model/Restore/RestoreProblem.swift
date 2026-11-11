import DirBuffKit
import Foundation

/// A restore that didn't happen, as an alert or a sheet shows it: a title, the sentence
/// `backupErrorWords` gives for the error with what to do about it, and the one fix the place it is
/// shown can offer. Nothing in the user's folders was overwritten: a restore writes beside the
/// original, or into a new folder, and every problem says so.
public struct RestoreProblem: Sendable, Equatable {
  /// What the user can do from where the problem is shown.
  public enum Fix: Sendable, Equatable {
    /// Nothing but read: the words say what to change outside DirBuff.
    case none
    /// Choose another folder to restore into.
    case chooseFolder
    /// Sign in to Google again.
    case signIn
    /// Signed in to another Google account than the backup's, or none is confirmed yet: the
    /// sign-in sheet's account step.
    case chooseAccount
    /// Type the backup's password.
    case enterPassword
    /// Ask again.
    case tryAgain

    /// The button's title; nil when there is none.
    public var title: String? {
      switch self {
      case .none: nil
      case .chooseFolder: "Choose Folder…"
      case .signIn: "Sign In Again…"
      case .chooseAccount: "Choose Account…"
      case .enterPassword: "Enter Password…"
      case .tryAgain: "Try Again"
      }
    }

    /// Whether the fix opens the sign-in sheet, which an alert offers as a button of its own.
    public var isSignIn: Bool { self == .signIn || self == .chooseAccount }
  }

  /// What was being restored, for the title.
  public enum Subject: Sendable, Equatable {
    /// Restore a Copy of the file with this name.
    case copy(name: String)
    /// Restore Folder of the folder with this name.
    case folder(name: String)
    /// Restore from Google Drive, and Keep Backing Up Here.
    case backup
  }

  public var title: String
  public var message: String
  public var fix: Fix

  public init(title: String, message: String, fix: Fix = .none) {
    self.title = title
    self.message = message
    self.fix = fix
  }

  /// The problem for `error`, thrown while restoring `subject`.
  public init(_ error: any Error, while subject: Subject) {
    title =
      switch subject {
      case .copy(let name), .folder(let name): "Couldn't restore \(name)"
      case .backup: "Couldn't restore from Google Drive"
      }
    fix = Self.fix(for: error, subject)
    let words = Self.words(error)
    message = [words, Self.hint(error, subject), Self.untouched].compactMap(\.self)
      .joined(separator: " ")
  }

  /// Said at the end of every problem that stopped a restore.
  public static let untouched = "Nothing in your folders was changed."

  private static func words(_ error: any Error) -> String {
    let error = error as NSError
    if error.domain == NSPOSIXErrorDomain, error.code == Int(POSIXErrorCode.ENOSPC.rawValue) {
      return "The disk ran out of room before the restore finished."
    }
    if error is CancellationError { return "The restore was cancelled." }
    return backupErrorWords(error as any Error) ?? error.localizedDescription
  }

  /// What to do next, where `backupErrorWords` (which says what happened) doesn't already.
  private static func hint(_ error: any Error, _ subject: Subject) -> String? {
    switch error {
    case BackupBuff.Failure.notEnoughRoom:
      subject.canChooseFolder
        ? "Free up some space, or choose a folder on a disk with more room."
        : "Free up some space, then try again."
    case BackupBuff.Failure.passwordNeeded, BackupBuff.Failure.passwordDoesNotOpen:
      subject.isCopy
        ? "Restore a Copy reads the password only from this Mac's Keychain and can't ask for it. Restore Folder asks: restore the folder, then copy the file from it."
        : "Enter it to open the backup."
    case BackupBuff.Failure.accountProblem(.signedOut): "Sign in again, then restore."
    case BackupBuff.Failure.accountProblem(.otherAccount),
      DriveAccount.Failure.backupInAnotherAccount:
      "Choose the backup's account, or start a new backup in this one, from the folder's card."
    case BackupBuff.Failure.accountProblem(.unconfirmed): nil
    case BackupBuff.Failure.accountProblem(.full): "Make room in it, then try again."
    case BackupBuff.Failure.accountProblem(.backupGone):
      "If it was deleted by mistake, look in Google Drive's Bin."
    case BackupBuff.Failure.accountProblem(.backupInBin):
      "Put it back from the Backup folder's card, then restore."
    case ResticFailure.stalled: "Check your connection, then try again."
    default: nil
    }
  }

  private static func fix(for error: any Error, _ subject: Subject) -> Fix {
    switch error {
    case BackupBuff.Failure.notEnoughRoom, BackupBuff.Failure.cannotWrite:
      subject.canChooseFolder ? .chooseFolder : .none
    case BackupBuff.Failure.passwordNeeded, BackupBuff.Failure.passwordDoesNotOpen:
      subject.isCopy ? .none : .enterPassword
    case BackupBuff.Failure.accountProblem(.signedOut), DriveProblem.signedOut: .signIn
    case BackupBuff.Failure.accountProblem(.otherAccount),
      BackupBuff.Failure.accountProblem(.unconfirmed), DriveAccount.Failure.backupInAnotherAccount:
      .chooseAccount
    case BackupBuff.Failure.accountProblem(.full), BackupBuff.Failure.backupIsEmpty,
      DriveProblem.unreachable, DriveProblem.rateLimited, DriveProblem.dailyUploadLimit,
      DriveProblem.storageFull, DriveProblem.notFound, DriveProblem.checksumMismatch,
      DriveProblem.rejected, ResticFailure.stalled, ResticFailure.exited, ResticFailure.unusable:
      .tryAgain
    default:
      (error as NSError).domain == NSPOSIXErrorDomain
        && (error as NSError).code == Int(POSIXErrorCode.ENOSPC.rawValue)
        ? (subject.canChooseFolder ? .chooseFolder : .none) : .none
    }
  }
}

extension RestoreProblem.Subject {
  fileprivate var isCopy: Bool {
    if case .copy = self { return true }
    return false
  }

  /// Whether another folder to restore into is a way out: a copy lands beside its original.
  fileprivate var canChooseFolder: Bool { !isCopy }
}
