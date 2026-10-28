import DirBuffCore
import SwiftUI

/// A folder's page, pushed over the shelf: its buffs as cards, and each one's setting.
public struct FolderPage: View {
  public var folder: MainFolder
  public var binName: String
  public var licenceRefusal: String?
  public var buyTitle: String
  public var onSetTemporary: (Bool) -> Void
  public var onChangeSettings: (TemporarySettings) -> Void
  public var onBuy: () -> Void

  public init(
    folder: MainFolder,
    binName: String = SystemBin.name,
    licenceRefusal: String? = nil,
    buyTitle: String = LicenceLine.Action.buy.title,
    onSetTemporary: @escaping (Bool) -> Void = { _ in },
    onChangeSettings: @escaping (TemporarySettings) -> Void = { _ in },
    onBuy: @escaping () -> Void = {}
  ) {
    self.folder = folder
    self.binName = binName
    self.licenceRefusal = licenceRefusal
    self.buyTitle = buyTitle
    self.onSetTemporary = onSetTemporary
    self.onChangeSettings = onChangeSettings
    self.onBuy = onBuy
  }

  public var body: some View {
    FolderDetailView(
      folder: folder,
      binName: binName,
      licenceRefusal: licenceRefusal,
      buyTitle: buyTitle,
      onSetTemporary: onSetTemporary,
      onChangeSettings: onChangeSettings,
      onBuy: onBuy
    )
    .navigationTitle(folder.name)
  }
}
