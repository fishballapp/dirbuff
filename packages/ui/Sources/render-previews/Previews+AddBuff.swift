import DirBuffUI
import SwiftUI

/// + Buff, the buff pieces, and dragging a buff onto a folder: the popover with no folder selected,
/// on a folder that wears Temporary and on one it can go on, the torn-off panel, the folder last
/// opened selected on the shelf, Temporary in the air over it (lit, refused, protected), and the
/// card after a drop.
@MainActor
func addBuffPreviews() -> [Preview] {
  let shelf = Samples.addBuffShelf
  let scratch = Samples.addBuffFolder("Scratch")
  let shelfSize = CGSize(width: 1040, height: 600)

  func popover(_ target: AddBuffTarget?, hovered: Buff? = nil) -> AnyView {
    AnyView(
      AddBuffList(target: target, onAdd: { _, _ in }, onChooseFolder: {}, hoveredBuff: hovered)
        .background(.regularMaterial))
  }

  func dragging(over folderID: Int64?) -> AnyView {
    AnyView(
      MainView(state: shelf, navigation: .constant(MainNavigation()))
        .environment(
          \.addBuffHost, AddBuffHost(draggedBuff: .temporary, dropFolderID: folderID)))
  }

  return [
    ("addbuff-popover-no-folder", popover(nil), nil),
    (
      "addbuff-popover-added",
      popover(shelf.addBuffTarget(Samples.addBuffFolder("Downloads"))), nil
    ),
    ("addbuff-popover-add-hover", popover(shelf.addBuffTarget(scratch), hovered: .temporary), nil),
    (
      "addbuff-panel",
      AnyView(BuffsPanelView().frame(maxHeight: .infinity, alignment: .top)),
      CGSize(width: 236, height: 230)
    ),
    (
      "addbuff-pieces",
      AnyView(
        HStack(spacing: 12) {
          ForEach(Buff.allCases, id: \.self) { BuffPiece($0).fixedSize() }
        }
        .padding(24)
        .background(Palette.paper)),
      nil
    ),
    (
      "addbuff-shelf-selected",
      AnyView(
        MainView(
          state: shelf, navigation: .constant(MainNavigation()),
          initialSelectedFolderID: scratch.id)),
      shelfSize
    ),
    ("addbuff-drag-lit", dragging(over: scratch.id), shelfSize),
    ("addbuff-drag-refused", dragging(over: Samples.addBuffFolder("Downloads").id), shelfSize),
    (
      "addbuff-added-card",
      AnyView(
        AddedBuffCard(
          folderName: scratch.name, folderPath: scratch.path, binName: Samples.binName,
          onChangeMaxAge: { _ in }, onUndo: {}, onDone: {}
        )
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)),
      CGSize(width: 268, height: 132)
    ),
  ]
}
