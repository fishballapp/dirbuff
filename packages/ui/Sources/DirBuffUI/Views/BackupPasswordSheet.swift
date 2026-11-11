import SwiftUI

/// Protect with a Password… and Change Password…: the password typed twice, a passphrase
/// suggested, and plainly what losing it costs.
public struct BackupPasswordSheet: View {
  public var state: BackupPasswordSheetState
  public var onSave: (String) -> Void
  public var onCancel: () -> Void

  @State private var password: String
  @State private var confirmation: String
  /// Whether either field changed since the last failure came back.
  @State private var isEdited = false

  public init(
    state: BackupPasswordSheetState,
    password: String = "",
    confirmation: String = "",
    onSave: @escaping (String) -> Void = { _ in },
    onCancel: @escaping () -> Void = {}
  ) {
    self.state = state
    self.onSave = onSave
    self.onCancel = onCancel
    self._password = State(initialValue: password)
    self._confirmation = State(initialValue: confirmation)
  }

  private var problem: String? {
    BackupPasswordSheetState.problem(password: password, confirmation: confirmation)
  }

  public var body: some View {
    if state.isFinishing {
      finishing
    } else {
      form
    }
  }

  /// The change failed after the Keychain took the new password: it is set.
  private var finishing: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("The password is set")
          .font(.headline)
          .foregroundStyle(Palette.ink)
        Text(
          "Google Drive couldn't finish the change just now, so the next backup finishes it. From now on the backup opens only with this password: keep it in a password manager."
        )
        .foregroundStyle(Palette.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Done", action: onCancel)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460)
    .background(Palette.paper)
  }

  private var form: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text(
          state.mode == .set ? "Protect the backup with a password" : "Change the backup's password"
        )
        .font(.headline)
        .foregroundStyle(Palette.ink)
        Text(
          "From now on the backup in Google Drive opens only with this password. A few unrelated words, like a short sentence, make a good one."
        )
        .foregroundStyle(Palette.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        GridRow {
          Text("Password").gridColumnAlignment(.trailing)
          SecureField(
            "At least \(BackupPasswordSheetState.minimumLength) characters", text: $password
          )
          .labelsHidden()
        }
        GridRow {
          Text("Again")
          SecureField("The same password", text: $confirmation)
            .labelsHidden()
        }
      }
      .disabled(state.isSaving)

      Text(
        "If you lose it, you lose the backup: nobody can recover it, DirBuff included. Keep it in a password manager."
      )
      .fontWeight(.semibold)
      .foregroundStyle(Palette.ink)
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        if state.isSaving {
          ProgressView().controlSize(.small)
          Text("Changing the backup's key…")
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
        } else if let footnote = state.footnote(
          password: password, confirmation: confirmation, isEdited: isEdited)
        {
          Text(footnote)
            .font(.subheadline)
            .foregroundStyle(
              footnote == state.failure ? Palette.inkSecondary : Palette.inkTertiary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
          .disabled(state.isSaving)
        Button(state.mode == .set ? "Protect" : "Change Password") { onSave(password) }
          .keyboardShortcut(.defaultAction)
          .disabled(problem != nil || state.isSaving)
      }
    }
    .padding(20)
    .frame(width: 460)
    .background(Palette.paper)
    .onChange(of: password) { isEdited = true }
    .onChange(of: confirmation) { isEdited = true }
    .onChange(of: state.failure) { isEdited = false }
  }
}
