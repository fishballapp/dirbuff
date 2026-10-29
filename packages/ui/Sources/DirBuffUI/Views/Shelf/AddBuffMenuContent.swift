import AppKit
import SwiftUI

/// Menu items for adding a buff to one folder: headed "Add a Buff to <Name>", listing only the
/// buffs it doesn't wear yet. Shared by a tile's hover + Buff button and its right-click Add Buff.
struct FolderAddBuffMenuContent: View {
  var folderName: String
  var items: [AddBuffItem]
  var onAddBuff: (Buff) -> Void

  private var availableItems: [AddBuffItem] {
    items.filter { $0.buff.isAvailable }
  }

  private var soonItems: [AddBuffItem] {
    items.filter { !$0.buff.isAvailable }
  }

  var body: some View {
    Section("Add a Buff to \(folderName)") {
      ForEach(availableItems) { item in
        buffMenuButton(item) {
          onAddBuff(item.buff)
        }
      }
      if !availableItems.isEmpty && !soonItems.isEmpty {
        Divider()
      }
      ForEach(soonItems) { item in
        buffMenuButton(item, action: {})
      }
    }
  }
}

@ViewBuilder
private func buffMenuButton(_ item: AddBuffItem, action: @escaping () -> Void) -> some View {
  Button(action: action) {
    Label {
      Text(item.buff.name)
      if let subtitle = item.subtitle {
        Text(subtitle)
      }
    } icon: {
      Image(nsImage: buffMenuImage(item.buff))
    }
  }
  .disabled(!item.isEnabled)
}

/// Renders `BuffOutline` into a 23 × 16 pt template `NSImage` so AppKit `NSMenu` draws the buff's
/// line symbol in light, dark, highlighted and disabled menu items.
func buffMenuImage(_ buff: Buff) -> NSImage {
  let width = BuffSymbol.Size.menu.rawValue
  let scale = width / BuffOutline.gridWidth
  let size = NSSize(width: width, height: (BuffOutline.gridHeight * scale).rounded())
  let image = NSImage(size: size, flipped: true) { rect in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }
    let path = BuffOutline(buff: buff).path(in: rect).cgPath
    context.addPath(path)
    context.setStrokeColor(NSColor.black.cgColor)
    context.setLineWidth(2.8 * scale)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    return true
  }
  image.isTemplate = true
  return image
}
