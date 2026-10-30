import SwiftUI

/// A folder's row in the sidebar: its 28 pt icon and mark, its name, and beneath it the symbols of
/// the buffs it wears or what it says instead ("No buffs", "Not connected"). A buff dragged over it
/// says there what letting go does. Selecting it is the list's own click, so the row carries no
/// gesture of its own.
struct SidebarFolderRow: View {
  var row: SidebarFolder
  var addBuffItems: [AddBuffItem]
  var mayClean: Bool
  var onAddBuff: (Buff) -> Void

  @Environment(\.addBuffHost) private var host
  /// Raised while the row is selected in a key window, where it sits on Accent Blue.
  @Environment(\.backgroundProminence) private var prominence

  private var isSelected: Bool { prominence == .increased }

  /// What letting go of the buff in the air would do here; nil while none is.
  private var dropVerdict: BuffDropVerdict? {
    host.draggedBuff.map {
      BuffDropVerdict.of($0, on: row.folder, items: addBuffItems, mayClean: mayClean)
    }
  }

  private var isDropTarget: Bool {
    host.draggedBuff != nil && host.dropFolderID == row.id
  }

  var body: some View {
    HStack(spacing: 10) {
      MarkedFolderIcon(path: row.folder.path, mark: row.folder.mark, size: .sidebar)
        .opacity(row.condition == .unplugged ? 0.55 : 1)
        .opacity(dropVerdict == .protected ? 0.38 : 1)
      VStack(alignment: .leading, spacing: 3) {
        Text(row.title)
          .fontWeight(row.condition == .needsYou ? .semibold : .medium)
          .foregroundStyle(titleStyle)
          .opacity(dropVerdict == .protected ? 0.38 : 1)
          .lineLimit(1)
          .truncationMode(.middle)
        subline
      }
      Spacer(minLength: 0)
      if row.condition == .needsYou && !isDropTarget {
        NeedsYouBadge(size: 16)
      }
    }
    .padding(.vertical, 3)
    .contentShape(.rect)
    .listRowBackground(ground)
    .buffDrop(on: row.id, verdict: dropVerdict, onAdd: onAddBuff)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  /// The second line: what a buff in the air would do, or the buffs worn.
  @ViewBuilder
  private var subline: some View {
    switch (isDropTarget, dropVerdict) {
    case (true, .add(let line)):
      rowCapsule(line, isAccepting: true)
    case (true, .refused(let reason)):
      rowCapsule(reason, isAccepting: false)
    case (_, .protected):
      Text("Protected")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Palette.inkSecondary)
    default:
      HStack(spacing: 6) {
        ForEach(row.buffs, id: \.self) { buff in
          BuffSymbol(buff, size: .sidebar)
        }
        if let note = row.note {
          Text(note)
            .font(.subheadline)
            .lineLimit(1)
        }
      }
      .foregroundStyle(sublineStyle)
      .frame(height: 13)
    }
  }

  /// The drop's capsule, starting under the icon so the whole line fits a sidebar at its usual
  /// width.
  private func rowCapsule(_ text: String, isAccepting: Bool) -> some View {
    DropCapsule(text: text, isAccepting: isAccepting, font: .caption.weight(.semibold))
      .minimumScaleFactor(0.85)
      .padding(.leading, -38)
  }

  private var titleStyle: AnyShapeStyle {
    if isSelected { return AnyShapeStyle(.primary) }
    return AnyShapeStyle(row.condition == .unplugged ? Palette.inkSecondary : Palette.ink)
  }

  private var sublineStyle: AnyShapeStyle {
    if isSelected { return AnyShapeStyle(.secondary) }
    if row.buffs.isEmpty { return AnyShapeStyle(Palette.inkTertiary) }
    return switch row.condition {
    case .atRest: AnyShapeStyle(Palette.inkSecondary)
    case .needsYou: AnyShapeStyle(Palette.amberText)
    case .unplugged, .paused: AnyShapeStyle(Palette.quiet)
    }
  }

  /// A drop that takes lights the row Blue Tint inside an Accent Blue ring; a needs-you row sits on
  /// Amber Tint inside the Amber Edge. The selection's own ground covers either.
  @ViewBuilder
  private var ground: some View {
    let shape = RoundedRectangle(cornerRadius: Metrics.sidebarRowRadius)
    Group {
      if isDropTarget, dropVerdict?.isAdding == true {
        shape.fill(Palette.blueTint).strokeBorder(Palette.accentBlue, lineWidth: 1.5)
      } else if row.condition == .needsYou && !isSelected {
        shape.fill(Palette.amberTint).strokeBorder(Palette.amberEdge, lineWidth: 1)
      } else {
        Color.clear
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 1)
  }

  private var accessibilityLabel: String {
    let buffs = row.buffs.map(\.name).joined(separator: ", ")
    let worn = row.buffs.isEmpty ? "no buffs" : buffs
    let state =
      switch row.condition {
      case .atRest: ""
      case .needsYou: ", needs you"
      case .unplugged: ", not connected"
      case .paused: ", paused"
      }
    return "\(row.title), \(worn)\(state)"
  }
}
