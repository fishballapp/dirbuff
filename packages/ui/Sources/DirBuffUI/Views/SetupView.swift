import SwiftUI

/// Live checklist for DirBuff initial setup (~440 pt wide).
public struct SetupView: View {
  public var state: SetupState
  public var onOpenExtensionManagement: () -> Void
  public var onToggleOpenAtLogin: (Bool) -> Void
  public var onOpenLoginItemsSettings: () -> Void
  public var onRequestNotifications: () -> Void

  public init(
    state: SetupState,
    onOpenExtensionManagement: @escaping () -> Void = {},
    onToggleOpenAtLogin: @escaping (Bool) -> Void = { _ in },
    onOpenLoginItemsSettings: @escaping () -> Void = {},
    onRequestNotifications: @escaping () -> Void = {}
  ) {
    self.state = state
    self.onOpenExtensionManagement = onOpenExtensionManagement
    self.onToggleOpenAtLogin = onToggleOpenAtLogin
    self.onOpenLoginItemsSettings = onOpenLoginItemsSettings
    self.onRequestNotifications = onRequestNotifications
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 4) {
        Text("DirBuff Setup")
          .font(.headline)
        Text("Configure Finder integration and background cleaning.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 16) {
        extensionRow

        Divider()

        loginItemRow

        Divider()

        notificationsRow
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  // MARK: - Extension Row

  @ViewBuilder
  private var extensionRow: some View {
    HStack(alignment: .top, spacing: 12) {
      statusIcon(isDone: state.isExtensionEnabled)

      VStack(alignment: .leading, spacing: 4) {
        Text("Turn on the Finder extension")
          .font(.body)
          .fontWeight(.medium)

        Text("Adds \"Add to DirBuff…\" to Finder's right-click menu.")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        if !state.isExtensionEnabled {
          VStack(alignment: .leading, spacing: 6) {
            Button("Open Extension Settings…") {
              onOpenExtensionManagement()
            }
            .controlSize(.small)

            Text("System Settings › General › Login Items & Extensions")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.top, 4)
        }
      }

      Spacer()
    }
  }

  // MARK: - Login Item Row

  @ViewBuilder
  private var loginItemRow: some View {
    HStack(alignment: .top, spacing: 12) {
      statusIcon(isDone: state.isOpenAtLogin)

      VStack(alignment: .leading, spacing: 4) {
        Text("Open at login")
          .font(.body)
          .fontWeight(.medium)

        Text("Clears temporary folders in the background on launch, hourly, and after wake.")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        if state.isOpenAtLoginRequiresApproval {
          Button("Open Login Items…") {
            onOpenLoginItemsSettings()
          }
          .controlSize(.small)
          .padding(.top, 4)
        } else if !state.isOpenAtLogin {
          Button("Enable at Login") {
            onToggleOpenAtLogin(true)
          }
          .controlSize(.small)
          .padding(.top, 4)
        }
      }

      Spacer()
    }
  }

  // MARK: - Notifications Row

  @ViewBuilder
  private var notificationsRow: some View {
    HStack(alignment: .top, spacing: 12) {
      statusIcon(isDone: state.isNotificationsEnabled)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          Text("Notifications")
            .font(.body)
            .fontWeight(.medium)
          Text("(optional)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Text("A calm daily summary before items are removed.")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        if !state.isNotificationsEnabled {
          Button("Allow Notifications") {
            onRequestNotifications()
          }
          .controlSize(.small)
          .padding(.top, 4)
        }
      }

      Spacer()
    }
  }

  // MARK: - Status Icon

  @ViewBuilder
  private func statusIcon(isDone: Bool) -> some View {
    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
      .font(.title3)
      .foregroundStyle(isDone ? Color.accentColor : Color.secondary)
      .accessibilityLabel(isDone ? "Completed" : "Not completed")
      .padding(.top, 1)
  }
}
