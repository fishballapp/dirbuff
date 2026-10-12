import SwiftUI

/// DirBuff Settings: one grouped form, changes apply at once.
public struct SettingsView: View {
  public var state: SettingsState
  public var onToggleOpenAtLogin: (Bool) -> Void
  public var onToggleShowInMenuBar: (Bool) -> Void
  public var onOpenLoginItemsSettings: () -> Void
  public var onOpenSetup: () -> Void
  public var onBuy: () -> Void
  public var onEnterKey: () -> Void
  public var onManageSubscription: () -> Void
  public var onDeactivate: () -> Void

  public init(
    state: SettingsState,
    onToggleOpenAtLogin: @escaping (Bool) -> Void = { _ in },
    onToggleShowInMenuBar: @escaping (Bool) -> Void = { _ in },
    onOpenLoginItemsSettings: @escaping () -> Void = {},
    onOpenSetup: @escaping () -> Void = {},
    onBuy: @escaping () -> Void = {},
    onEnterKey: @escaping () -> Void = {},
    onManageSubscription: @escaping () -> Void = {},
    onDeactivate: @escaping () -> Void = {}
  ) {
    self.state = state
    self.onToggleOpenAtLogin = onToggleOpenAtLogin
    self.onToggleShowInMenuBar = onToggleShowInMenuBar
    self.onOpenLoginItemsSettings = onOpenLoginItemsSettings
    self.onOpenSetup = onOpenSetup
    self.onBuy = onBuy
    self.onEnterKey = onEnterKey
    self.onManageSubscription = onManageSubscription
    self.onDeactivate = onDeactivate
  }

  public var body: some View {
    Form {
      Section("Licence") {
        Text(state.licence.status(key: state.licenceKey))
        HStack {
          Spacer()
          if state.licence.hasKey {
            Button("Deactivate This Mac…", action: onDeactivate)
            Button("Manage Subscription…", action: onManageSubscription)
          } else {
            Button("Enter Licence Key…", action: onEnterKey)
            Button("Buy DirBuff…", action: onBuy)
          }
        }
      }

      Section {
        Toggle(
          "Open at login",
          isOn: Binding(get: { state.openAtLogin }, set: { onToggleOpenAtLogin($0) }))

        if state.openAtLoginRequiresApproval {
          LabeledContent {
            Button("Open Login Items…", action: onOpenLoginItemsSettings)
          } label: {
            Text("Needs your approval in System Settings.")
              .foregroundStyle(.secondary)
          }
        }

        Toggle(
          "Show in menu bar",
          isOn: Binding(get: { state.showInMenuBar }, set: { onToggleShowInMenuBar($0) }))
      } footer: {
        Text("DirBuff keeps clearing your folders when its icon is hidden.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        LabeledContent("Finder extension, login and notifications") {
          Button("Set Up…", action: onOpenSetup)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 420)
  }
}
