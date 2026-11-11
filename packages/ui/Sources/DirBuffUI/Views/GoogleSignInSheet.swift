import SwiftUI

/// The Google sign-in sheet, drawn as the design reference does: Backup's symbol, a heading and a
/// sentence, and the buttons trailing. Google's own sign-in opens in the browser; nothing about
/// the account's storage is shown.
public struct GoogleSignInSheet: View {
  public var state: GoogleSignInState
  /// Sign In with Google…, and Try Again….
  public var onSignIn: () -> Void
  /// Not Now, and Cancel while the browser is open: the folder waits.
  public var onDismiss: () -> Void
  /// Start Backup, Carry On or Done, once signed in.
  public var onConfirm: () -> Void
  /// Use Another Account…: signs out and asks again.
  public var onUseAnotherAccount: () -> Void
  /// Start a New Backup Here…: asks, then makes a new backup in the account signed in.
  public var onStartNewBackup: () -> Void

  public init(
    state: GoogleSignInState,
    onSignIn: @escaping () -> Void = {},
    onDismiss: @escaping () -> Void = {},
    onConfirm: @escaping () -> Void = {},
    onUseAnotherAccount: @escaping () -> Void = {},
    onStartNewBackup: @escaping () -> Void = {}
  ) {
    self.state = state
    self.onSignIn = onSignIn
    self.onDismiss = onDismiss
    self.onConfirm = onConfirm
    self.onUseAnotherAccount = onUseAnotherAccount
    self.onStartNewBackup = onStartNewBackup
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top, spacing: 14) {
        BuffSymbol(.backup, size: .card)
          .foregroundStyle(Palette.accentBlue)
          .padding(.top, 2)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          heading
            .font(.headline)
            .foregroundStyle(Palette.ink)
          Text(state.detail)
            .foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
          if state.step == .waiting {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("Waiting for Google in your browser…")
                .font(.subheadline)
                .foregroundStyle(Palette.inkTertiary)
            }
            .padding(.top, 4)
          }
        }
      }
      HStack(spacing: 8) {
        Spacer()
        buttons
      }
    }
    .padding(20)
    // Three buttons stand side by side at the other-account step, each title in full.
    .frame(width: isOtherAccount ? 560 : 460)
    .background(Palette.paper)
  }

  @ViewBuilder
  private var heading: some View {
    if case .signedIn(let account) = state.step {
      HStack(spacing: 5) {
        switch state.reason {
        case .backUp(let name, let path):
          Text("Back up")
          FolderPill(name, path: path)
          Text("to \(account ?? "your Google Drive")")
            .lineLimit(1)
            .truncationMode(.middle)
        case .signInAgain:
          Text("Carry on backing up to \(account ?? "your Google Drive")")
        case .settings, .restore:
          Text(account.map { "Signed in as \($0)" } ?? "Signed in to Google Drive")
        }
      }
    } else {
      Text(state.title)
    }
  }

  private var isOtherAccount: Bool {
    if case .otherAccount = state.step { return true }
    return false
  }

  @ViewBuilder
  private var buttons: some View {
    switch state.step {
    case .ask:
      Button("Not Now", action: onDismiss)
        .keyboardShortcut(.cancelAction)
      Button("Sign In with Google…", action: onSignIn)
        .keyboardShortcut(.defaultAction)
    case .waiting:
      Button("Cancel", action: onDismiss)
        .keyboardShortcut(.cancelAction)
    case .signedIn:
      Button("Use Another Account…", action: onUseAnotherAccount)
      Button(state.confirmTitle, action: onConfirm)
        .keyboardShortcut(.defaultAction)
    case .otherAccount:
      Button("Not Now", action: onDismiss)
        .keyboardShortcut(.cancelAction)
      Button("Start a New Backup Here…", action: onStartNewBackup)
      Button("Use Another Account…", action: onUseAnotherAccount)
        .keyboardShortcut(.defaultAction)
    case .failed:
      Button("Not Now", action: onDismiss)
        .keyboardShortcut(.cancelAction)
      Button("Try Again…", action: onSignIn)
        .keyboardShortcut(.defaultAction)
    }
  }
}
