import DirBuffKit
import Foundation

/// Settings › Backup: the Google account Backup goes to, and the backup's optional password.
public struct BackupAccountSettings: Sendable, Equatable {
  /// Whether DirBuff holds a Google sign-in.
  public var isSignedIn: Bool
  /// The account, when DirBuff knows it: "mei.chan@gmail.com".
  public var account: String?
  /// Whether the backup opens only with a password, which this Mac keeps in its Keychain.
  public var isPasswordProtected: Bool

  public init(isSignedIn: Bool, account: String? = nil, isPasswordProtected: Bool = false) {
    self.isSignedIn = isSignedIn
    self.account = account
    self.isPasswordProtected = isPasswordProtected
  }

  /// Under "Google Drive".
  var accountLine: String {
    guard isSignedIn else { return "Not signed in. Backup folders wait until you sign in." }
    return account ?? "Signed in"
  }

  /// Under "Password".
  var passwordLine: String {
    isPasswordProtected
      ? "The backup opens only with your password. This Mac keeps it in its Keychain."
      : "None. Anyone who can open your Google account can read the backup, as they can your mail."
  }

  /// What the section's buttons do.
  public enum Action: Sendable, Equatable {
    case signIn
    case signOut
    case setPassword
    case changePassword
    case removePassword
  }
}

/// Protect with a Password… and Change Password…: the password typed twice, with what it costs to
/// lose it.
public struct BackupPasswordSheetState: Sendable, Equatable, Identifiable {
  public enum Mode: Sendable, Equatable {
    case set
    case change
  }

  public let id = UUID()
  public var mode: Mode
  /// While the backup's keys change.
  public var isSaving: Bool
  /// Why the last try failed, in words.
  public var failure: String?
  /// The change failed after the Keychain took the new password: the backup opens with it, and
  /// the next backup finishes the change.
  public var isFinishing: Bool

  public init(
    mode: Mode, isSaving: Bool = false, failure: String? = nil, isFinishing: Bool = false
  ) {
    self.mode = mode
    self.isSaving = isSaving
    self.failure = failure
    self.isFinishing = isFinishing
  }

  /// After a try that failed: if the Keychain holds the new password, the change is pending and
  /// the next command finishes it, so the password is set; else why it failed.
  public func afterFailure(_ words: String, isNewPasswordKept: Bool) -> Self {
    var next = self
    next.isSaving = false
    next.isFinishing = isNewPasswordKept
    next.failure = isNewPasswordKept ? nil : words
    return next
  }

  /// The line beside the buttons: the last failure until the user edits, then what's still
  /// wrong with what they typed, if anything.
  public func footnote(password: String, confirmation: String, isEdited: Bool) -> String? {
    if let failure, !isEdited { return failure }
    guard !password.isEmpty else { return nil }
    return Self.problem(password: password, confirmation: confirmation)
  }

  /// The fewest characters a password may have.
  public static var minimumLength: Int { BackupBuff.minimumPasswordLength }

  /// Why `password` and `confirmation` can't be saved yet; nil when they can.
  public static func problem(password: String, confirmation: String) -> String? {
    if password.count < minimumLength {
      return "At least \(minimumLength) characters."
    }
    if password.trimmingCharacters(in: .whitespacesAndNewlines) != password {
      return "No space at the start or the end."
    }
    if confirmation != password { return "The two don't match yet." }
    return nil
  }
}
