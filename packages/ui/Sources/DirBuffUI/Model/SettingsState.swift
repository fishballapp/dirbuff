import DirBuffCore
import Foundation

/// Value type describing the state for DirBuff Settings.
public struct SettingsState: Sendable, Equatable {
  public var openAtLogin: Bool
  public var openAtLoginRequiresApproval: Bool
  public var showInMenuBar: Bool
  public var licence: Licence
  public var licenceKey: String?

  public init(
    openAtLogin: Bool = false,
    openAtLoginRequiresApproval: Bool = false,
    showInMenuBar: Bool = true,
    licence: Licence,
    licenceKey: String? = nil
  ) {
    self.openAtLogin = openAtLogin
    self.openAtLoginRequiresApproval = openAtLoginRequiresApproval
    self.showInMenuBar = showInMenuBar
    self.licence = licence
    self.licenceKey = licenceKey
  }
}
