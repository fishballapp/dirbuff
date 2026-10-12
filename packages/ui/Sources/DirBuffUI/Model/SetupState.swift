import Foundation

/// Value type describing the live checklist state for DirBuff Setup.
public struct SetupState: Sendable, Equatable {
  public var isExtensionEnabled: Bool
  public var isOpenAtLogin: Bool
  public var isOpenAtLoginRequiresApproval: Bool
  public var isNotificationsEnabled: Bool

  public init(
    isExtensionEnabled: Bool = false,
    isOpenAtLogin: Bool = false,
    isOpenAtLoginRequiresApproval: Bool = false,
    isNotificationsEnabled: Bool = false
  ) {
    self.isExtensionEnabled = isExtensionEnabled
    self.isOpenAtLogin = isOpenAtLogin
    self.isOpenAtLoginRequiresApproval = isOpenAtLoginRequiresApproval
    self.isNotificationsEnabled = isNotificationsEnabled
  }
}
