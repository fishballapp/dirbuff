import SwiftUI

/// DirBuff Settings: one window of grouped sections on Paper, changes applying at once.
public struct SettingsView: View {
  public var state: SettingsState
  public var onToggleOpenAtLogin: (Bool) -> Void
  public var onToggleShowInMenuBar: (Bool) -> Void
  public var onToggleGetDevBuilds: (Bool) -> Void
  public var onCheckForUpdates: () -> Void
  public var onOpenLoginItemsSettings: () -> Void
  public var onOpenSetup: () -> Void
  public var onLicenceAction: (LicenceSettings.Action) -> Void
  public var onBackupAction: (BackupAccountSettings.Action) -> Void

  public init(
    state: SettingsState,
    onToggleOpenAtLogin: @escaping (Bool) -> Void = { _ in },
    onToggleShowInMenuBar: @escaping (Bool) -> Void = { _ in },
    onToggleGetDevBuilds: @escaping (Bool) -> Void = { _ in },
    onCheckForUpdates: @escaping () -> Void = {},
    onOpenLoginItemsSettings: @escaping () -> Void = {},
    onOpenSetup: @escaping () -> Void = {},
    onLicenceAction: @escaping (LicenceSettings.Action) -> Void = { _ in },
    onBackupAction: @escaping (BackupAccountSettings.Action) -> Void = { _ in }
  ) {
    self.state = state
    self.onToggleOpenAtLogin = onToggleOpenAtLogin
    self.onToggleShowInMenuBar = onToggleShowInMenuBar
    self.onToggleGetDevBuilds = onToggleGetDevBuilds
    self.onCheckForUpdates = onCheckForUpdates
    self.onOpenLoginItemsSettings = onOpenLoginItemsSettings
    self.onOpenSetup = onOpenSetup
    self.onLicenceAction = onLicenceAction
    self.onBackupAction = onBackupAction
  }

  public var body: some View {
    Form {
      licenceSection

      Section {
        Toggle(
          "Open at login",
          isOn: Binding(get: { state.openAtLogin }, set: { onToggleOpenAtLogin($0) }))

        if state.openAtLoginRequiresApproval {
          LabeledContent {
            Button("Turn On…", action: onOpenLoginItemsSettings)
          } label: {
            Text("Needs your approval in System Settings.")
              .foregroundStyle(Palette.inkTertiary)
          }
        }

        Toggle(
          "Show in menu bar",
          isOn: Binding(get: { state.showInMenuBar }, set: { onToggleShowInMenuBar($0) }))
      } footer: {
        Text("DirBuff keeps working when its icon is hidden.")
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, 10)
      }

      Section {
        LabeledContent("Finder extension, login and notifications") {
          Button("Set Up…", action: onOpenSetup)
        }
      }

      backupSection

      Section {
        LabeledContent("DirBuff \(state.version)") {
          Button("Check for Updates…", action: onCheckForUpdates)
            .disabled(!state.canCheckForUpdates)
        }

        Toggle(
          isOn: Binding(get: { state.shouldGetDevBuilds }, set: { onToggleGetDevBuilds($0) })
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Get dev builds")
            Text("A build of every change, before it’s released")
              .font(.subheadline)
              .foregroundStyle(Palette.inkTertiary)
          }
        }
      } header: {
        SectionHead("Updates")
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(Palette.paper)
    .frame(width: 520)
  }

  private var backupSection: some View {
    let backup = state.backup
    return Section {
      LabeledContent {
        if backup.isSignedIn {
          Button("Sign Out…") { onBackupAction(.signOut) }
        } else {
          Button("Sign In with Google…") { onBackupAction(.signIn) }
        }
      } label: {
        labelled("Google Drive", backup.accountLine)
      }

      LabeledContent {
        if backup.isPasswordProtected {
          HStack(spacing: 8) {
            Button("Change Password…") { onBackupAction(.changePassword) }
            Button("Remove Password…") { onBackupAction(.removePassword) }
          }
          .disabled(!backup.isSignedIn)
        } else {
          Button("Protect with a Password…") { onBackupAction(.setPassword) }
            .disabled(!backup.isSignedIn)
        }
      } label: {
        labelled("Password", backup.passwordLine)
      }
    } header: {
      SectionHead("Backup")
    }
  }

  private func labelled(_ title: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      Text(detail)
        .font(.subheadline)
        .foregroundStyle(Palette.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var licenceSection: some View {
    let licence = state.licenceSettings
    return Section {
      VStack(alignment: .leading, spacing: 4) {
        Text(licence.headline)
        Text(licence.detail)
          .font(.subheadline)
          .foregroundStyle(Palette.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          if let primary = licence.primary {
            Button(primary.title) { onLicenceAction(primary) }
              .keyboardShortcut(.defaultAction)
          }
          ForEach(licence.others, id: \.self) { action in
            Button(action.title) { onLicenceAction(action) }
          }
        }
        .padding(.top, 6)
      }
      .padding(.vertical, 2)
    } header: {
      SectionHead("Licence")
    }
  }
}

/// A group's title: Subheadline, semibold, Ink Tertiary.
private struct SectionHead: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(Palette.inkTertiary)
  }
}
