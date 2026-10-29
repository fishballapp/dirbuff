import SwiftUI

/// What + Buff opens, 364 pt wide: a hint, one row per buff, and Choose Folder… for a folder not on
/// the shelf. A row drags onto any tile or out onto a folder in Finder; a click adds it to the
/// target folder.
public struct AddBuffList: View {
  var target: AddBuffTarget?
  var onAdd: (_ folderID: Int64, Buff) -> Void
  var onChooseFolder: () -> Void

  @State private var hoveredBuff: Buff?

  /// - Parameter hoveredBuff: The row the pointer starts over, for previews.
  public init(
    target: AddBuffTarget?,
    onAdd: @escaping (_ folderID: Int64, Buff) -> Void,
    onChooseFolder: @escaping () -> Void,
    hoveredBuff: Buff? = nil
  ) {
    self.target = target
    self.onAdd = onAdd
    self.onChooseFolder = onChooseFolder
    self._hoveredBuff = State(initialValue: hoveredBuff)
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      hint
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)

      VStack(spacing: 0) {
        ForEach(AddBuffRow.all(for: target)) { row in
          AddBuffRowView(row: row, isHovered: hoveredBuff == row.buff)
            .modifier(
              RowInteraction(
                row: row,
                onClick: { add(row) },
                onHover: { isOver in
                  if isOver {
                    hoveredBuff = row.buff
                  } else if hoveredBuff == row.buff {
                    hoveredBuff = nil
                  }
                }))
        }
      }
      .padding(.horizontal, 6)
      .padding(.bottom, 6)

      Divider()

      HStack(spacing: 10) {
        Text("A folder not shown here?")
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
        Spacer(minLength: 0)
        Button("Choose Folder…", action: onChooseFolder)
      }
      .padding(.top, 10)
      .padding(.leading, 16)
      .padding(.trailing, 12)
      .padding(.bottom, 12)
    }
    .frame(width: 364)
  }

  private var hint: some View {
    Group {
      if let folder = target?.folder {
        let pill = FolderPill(folder.name, path: folder.path)
        // The pill keeps the words that lead to it, so it never sits on a line alone.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 4) {
            Text("Drag onto a folder, here or in Finder, or click to add to")
            pill
          }
          VStack(alignment: .leading, spacing: 3) {
            Text("Drag onto a folder, here or in Finder, or")
            HStack(spacing: 4) {
              Text("click to add to")
              pill
            }
          }
        }
      } else {
        Text("Drag onto a folder, here or in Finder, or select a folder and click a buff")
      }
    }
    .font(.subheadline.weight(.semibold))
    .foregroundStyle(Palette.inkTertiary)
    .lineLimit(2)
    .fixedSize(horizontal: false, vertical: true)
  }

  private func add(_ row: AddBuffRow) {
    guard case .add = row.offer, let folder = target?.folder else { return }
    onAdd(folder.id, row.buff)
  }
}

/// A row that drags, and clicks to add when it can; a Soon row does neither.
private struct RowInteraction: ViewModifier {
  var row: AddBuffRow
  var onClick: () -> Void
  var onHover: (Bool) -> Void

  func body(content: Content) -> some View {
    if row.isDraggable {
      content.buffDragSource(row.buff, onClick: onClick, onHover: onHover)
    } else {
      content
    }
  }
}

/// One buff in + Buff: the 40 pt symbol in Accent Blue, the name in caps over one line of what it
/// does, and at the end what a click does. The row a click would add fills Accent Blue.
private struct AddBuffRowView: View {
  var row: AddBuffRow
  var isHovered: Bool

  private var isHighlighted: Bool {
    guard case .add = row.offer else { return false }
    return isHovered
  }

  var body: some View {
    HStack(spacing: 12) {
      BuffSymbol(row.buff, size: .addBuff)
        .foregroundStyle(symbolColor)
      VStack(alignment: .leading, spacing: 4) {
        BuffName(row.buff, size: .piece)
          .foregroundStyle(nameColor)
        Text(row.buff.summary)
          .font(.subheadline)
          .foregroundStyle(isHighlighted ? .white : Palette.inkTertiary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      trailing
        .font(.subheadline)
        .foregroundStyle(isHighlighted ? .white : Palette.inkTertiary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .background(
      isHighlighted ? Palette.accentBlue : .clear, in: .rect(cornerRadius: Metrics.pieceRadius)
    )
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var trailing: some View {
    switch row.offer {
    case .added:
      Label("Added", systemImage: "checkmark")
        .labelStyle(.titleAndIcon)
    case .add(let folderName):
      if isHovered { Text("Add to \(folderName)") }
    case .soon:
      Text("Soon")
    case .dragOnly:
      EmptyView()
    }
  }

  private var symbolColor: Color {
    if isHighlighted { return .white }
    return row.buff.isAvailable ? Palette.accentBlue : Palette.quiet
  }

  private var nameColor: Color {
    if isHighlighted { return .white }
    return row.buff.isAvailable ? Palette.ink : Palette.inkTertiary
  }
}
