import DirBuffUI
import SwiftUI

extension MainContainerView {
  /// A folder's page.
  @ViewBuilder
  func folderPage(_ id: Int64, state: MainState, now: Date) -> some View {
    if let folder = state.folders.first(where: { $0.id == id }) {
      FolderPage(
        folder: folder,
        licenceRefusal: state.licenceRefusal,
        buyTitle: state.buyTitle,
        onSetTemporary: { isOn in
          guard let record = appModel.folder(id: id) else { return }
          Task { await appModel.setTemporary(record, isOn) }
        },
        onChangeSettings: { settings in
          guard let record = appModel.folder(id: id) else { return }
          Task { await appModel.save(settings, for: record) }
        },
        onBuy: appModel.openCheckout
      )
    }
  }
}
