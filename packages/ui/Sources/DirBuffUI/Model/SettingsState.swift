import DirBuffCore
import Foundation

/// Value type describing the state for DirBuff Settings.
public struct SettingsState: Sendable, Equatable {
  public var openAtLogin: Bool
  public var openAtLoginRequiresApproval: Bool
  public var showInMenuBar: Bool
  public var shouldGetDevBuilds: Bool
  /// The version and build running, as `0.1.3 (2126)`.
  public var version: String
  public var canCheckForUpdates: Bool
  public var licence: Licence
  public var licenceKey: String?

  /// What the Licence section says and offers.
  public var licenceSettings: LicenceSettings { licence.settings(key: licenceKey) }

  public init(
    openAtLogin: Bool = false,
    openAtLoginRequiresApproval: Bool = false,
    showInMenuBar: Bool = true,
    shouldGetDevBuilds: Bool = false,
    version: String,
    canCheckForUpdates: Bool = true,
    licence: Licence,
    licenceKey: String? = nil
  ) {
    self.openAtLogin = openAtLogin
    self.openAtLoginRequiresApproval = openAtLoginRequiresApproval
    self.showInMenuBar = showInMenuBar
    self.shouldGetDevBuilds = shouldGetDevBuilds
    self.version = version
    self.canCheckForUpdates = canCheckForUpdates
    self.licence = licence
    self.licenceKey = licenceKey
  }
}
