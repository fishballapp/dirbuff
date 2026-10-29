import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One folder on the shelf: its 64 pt Finder icon and mark in a Well band on top, and one row
/// beneath for each buff it wears.
struct FolderTileView: View {
  var folder: FolderState
  var addBuffItems: [AddBuffItem]
  var canAddBuff: Bool
  /// The folder last opened: + Buff's click adds to it.
  var isSelected = false
  var actions: ShelfActions
  var onOpen: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var isReduceMotionOn
  @Environment(\.addBuffHost) private var host
  @State private var isHovered = false

  /// What letting go of the buff in the air would do here; nil while none is.
  private var dropVerdict: BuffDropVerdict? {
    host.draggedBuff.map {
      BuffDropVerdict.of($0, on: folder, items: addBuffItems, mayClean: canAddBuff)
    }
  }

  private var isDropTarget: Bool {
    host.draggedBuff != nil && host.dropFolderID == folder.id
  }

  var body: some View {
    VStack(spacing: 0) {
      folderBand
        // Its drop capsule straddles the rows below.
        .zIndex(1)
      ForEach(Array(folder.buffs.enumerated()), id: \.element.id) { index, row in
        if index > 0 {
          Palette.rule
            .frame(height: 1)
            .padding(.leading, 58)
        }
        buffRow(row)
      }
    }
    .background(Palette.card)
    .clipShape(.rect(cornerRadius: Metrics.tileRadius))
    .overlay {
      RoundedRectangle(cornerRadius: Metrics.tileRadius)
        .strokeBorder(borderColor, lineWidth: borderWidth)
    }
    .shadow(
      color: folder.isNeedingYou
        ? Color.black.opacity(colorScheme == .dark ? 0.34 : 0.08)
        : Color.black.opacity(colorScheme == .dark ? 0.30 : 0.07),
      radius: 8,
      x: 0,
      y: 3
    )
    .opacity(dropVerdict == .protected ? 0.38 : 1)
    .background { dropHalo }
    .overlay(alignment: .top) {
      if dropVerdict == .protected {
        protectedLabel
          // Over the foot of the 64 pt icon, which sits 22 pt down.
          .padding(.top, 70)
      }
    }
    .onDrop(
      of: [.dirbuffBuff],
      delegate: TileDropDelegate(
        folderID: folder.id,
        host: host,
        verdict: dropVerdict,
        onAdd: { actions.addBuff(folder.id, $0) })
    )
    .onHover { isHovered = $0 }
    .contextMenu {
      Menu("Add Buff") {
        FolderAddBuffMenuContent(
          folderName: folder.name,
          items: addBuffItems,
          onAddBuff: { actions.addBuff(folder.id, $0) }
        )
      }
      .disabled(!canAddBuff)

      Button("Show in Finder") {
        actions.showInFinder(folder.id)
      }
    }
  }

  /// The card after a buff was dropped here. Closing it any way but Undo keeps the buff.
  private var isShowingAddedCard: Binding<Bool> {
    Binding(
      get: { host.added?.folderID == folder.id },
      set: { isShown in
        if !isShown, host.added?.folderID == folder.id { host.added = nil }
      })
  }

  /// The tile under a buff it would take lights: a Blue Tint halo inside an Accent Blue ring.
  @ViewBuilder
  private var dropHalo: some View {
    if isDropTarget, case .add = dropVerdict {
      let outset: CGFloat = 6.5
      RoundedRectangle(cornerRadius: Metrics.tileRadius + outset)
        .fill(Palette.blueTint)
        .strokeBorder(Palette.accentBlue, lineWidth: 1.5)
        .padding(-outset)
    }
  }

  /// What letting go does, or in grey why not, on the band's lower edge.
  @ViewBuilder
  private var dropCapsule: some View {
    if isDropTarget {
      switch dropVerdict {
      case .add(let line): dropCapsule(line, fill: Palette.accentBlue)
      case .refused(let reason): dropCapsule(reason, fill: Self.refusedGrey)
      case .protected, nil: EmptyView()
      }
    }
  }

  /// Over a protected folder for as long as Temporary is in the air.
  private var protectedLabel: some View {
    Text("Protected")
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(Palette.ink)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Palette.card, in: .capsule)
      .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
  }

  /// The grey of a drop that won't take, the same in light and dark, so white reads on it.
  private static let refusedGrey = Color(red: 0x5A / 255, green: 0x5A / 255, blue: 0x55 / 255)

  private func dropCapsule(_ text: String, fill: Color) -> some View {
    Text(text)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(fill, in: .capsule)
      .shadow(color: .black.opacity(0.28), radius: 5, y: 3)
      .padding(.horizontal, 8)
  }

  private var borderColor: Color {
    if isSelected { return Palette.accentBlue }
    if folder.isNeedingYou { return Palette.amberEdge }
    return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.14)
  }

  private var borderWidth: CGFloat {
    if isSelected { return 2.5 }
    return folder.isNeedingYou ? 1 : 0.5
  }

  private var folderBand: some View {
    Button(action: onOpen) {
      VStack(spacing: 0) {
        MarkedFolderIcon(path: folder.path, mark: folder.mark, size: .tile)
          .animation(isReduceMotionOn ? nil : .easeOut(duration: 0.36), value: folder.mark)
          .popover(isPresented: isShowingAddedCard, arrowEdge: .bottom) {
            if let added = host.added {
              AddedBuffCard(
                folderName: folder.name,
                folderPath: folder.path,
                binName: SystemBin.name,
                onChangeMaxAge: { host.setMaxAge(folder.id, $0) },
                onUndo: {
                  host.added = nil
                  actions.undoAddBuff(folder.id, added.buff)
                },
                onDone: { host.added = nil })
            }
          }
          .padding(.bottom, 10)
        Text(folder.name)
          .font(.headline)
          .foregroundStyle(Palette.ink)
          .lineLimit(1)
        Text(folder.location)
          .font(.subheadline)
          .foregroundStyle(folder.isNeedingYou ? Palette.amberText : Palette.inkTertiary)
          .monospacedDigit()
          .lineLimit(1)
          .truncationMode(.middle)
          .padding(.top, 2)
      }
      .padding(.top, 22)
      .padding(.horizontal, 16)
      .padding(.bottom, 14)
      .frame(maxWidth: .infinity)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .background(folder.isNeedingYou ? Palette.amberTint : Palette.well)
    .overlay(alignment: .bottom) {
      (folder.isNeedingYou ? Palette.amberEdge : Palette.rule)
        .frame(height: 1)
    }
    .overlay(alignment: .bottom) {
      dropCapsule
        .alignmentGuide(.bottom) { $0[VerticalAlignment.center] }
    }
    .overlay(alignment: .topTrailing) {
      if isHovered && canAddBuff {
        Menu {
          FolderAddBuffMenuContent(
            folderName: folder.name,
            items: addBuffItems,
            onAddBuff: { actions.addBuff(folder.id, $0) }
          )
        } label: {
          Label("Buff", systemImage: "plus")
            .labelStyle(.titleAndIcon)
            .font(.subheadline.weight(.medium))
        }
        .menuIndicator(.hidden)
        .controlSize(.small)
        .padding(10)
        .accessibilityLabel("Add a buff to \(folder.name)")
      }
    }
  }

  private func buffRow(_ row: BuffRow) -> some View {
    HStack(alignment: .center, spacing: 14) {
      VStack(alignment: .leading, spacing: 0) {
        Button(action: onOpen) {
          HStack(alignment: .top, spacing: 14) {
            rowSymbol(row)
              .padding(.top, 1)

            VStack(alignment: .leading, spacing: 0) {
              BuffName(row.buff, size: .row)
                .foregroundStyle(row.isNeedsYou ? Palette.amberText : Palette.inkTertiary)
                .padding(.bottom, 6)

              // A paused row says only its setting and Paused; the capsule says why.
              if !row.state.isPaused {
                status(row)
              }

              if row.state == .working {
                workingBar
                  .padding(.top, 8)
                  .padding(.bottom, 6)
              }

              Text(row.setting)
                .font(.subheadline)
                .foregroundStyle(row.isNeedsYou ? Palette.inkSecondary : Palette.inkTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.top, row.state == .working || row.state.isPaused ? 0 : 2)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .contentShape(.rect)
        }
        .buttonStyle(.plain)

        // Outside the row's button, so a click opens Settings rather than the folder.
        if let reason = row.state.pillReason {
          PausedPill(reason: reason, onOpenLicence: actions.openLicenceSettings)
            .padding(.leading, 42)
            .padding(.top, 8)
        }

        if case .needsYou(let fix) = row.state {
          HStack(spacing: 8) {
            Button(fix.title) {
              actions.fix(folder.id, fix)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accentBlue)
            if fix == .locate {
              Button("Remove from DirBuff…") {
                actions.removeFolder(folder.id)
              }
            }
          }
          .controlSize(.small)
          .padding(.leading, 42)
          .padding(.top, 12)
        }
      }

      Button(action: onOpen) {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(row.isNeedsYou ? Palette.amberText.opacity(0.75) : Palette.quiet)
      }
      .buttonStyle(.plain)
      .accessibilityHidden(true)
    }
    .padding(.leading, 16)
    .padding(.trailing, 14)
    .padding(.vertical, 14)
    .background(row.isNeedsYou ? Palette.amberTint : .clear)
    .contentShape(.rect)
    .onTapGesture(perform: onOpen)
  }

  private func status(_ row: BuffRow) -> some View {
    HStack(spacing: 5) {
      Text(row.status)
      if let name = row.statusFolder {
        FolderPill(name, path: folder.path)
      }
    }
    .font(.body.weight(row.statusWeight))
    .foregroundStyle(row.statusColor)
    .monospacedDigit()
    .lineLimit(1)
  }

  private func rowSymbol(_ row: BuffRow) -> some View {
    BuffSymbol(row.buff, size: .row)
      .foregroundStyle(row.usesQuietSymbol ? Palette.quiet : Palette.ink)
      .overlay(alignment: .bottomTrailing) {
        if row.isNeedsYou {
          NeedsYouBadge(size: 16)
            .offset(x: 6, y: 5)
        }
      }
  }

  private var workingBar: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule()
          .fill(Palette.ruleStrong)
        Capsule()
          .fill(Palette.accentBlue)
          .frame(width: max(4, proxy.size.width * (folder.progress ?? 0)))
      }
    }
    .frame(height: 4)
  }

}

extension BuffRow {
  fileprivate var isNeedsYou: Bool {
    if case .needsYou = state { return true }
    return false
  }

  fileprivate var usesQuietSymbol: Bool {
    switch state {
    case .paused: true
    case .atRest, .working, .needsYou: false
    }
  }

  fileprivate var statusWeight: Font.Weight {
    switch state {
    case .needsYou: .semibold
    case .paused: .regular
    case .atRest, .working: .medium
    }
  }

  fileprivate var statusColor: Color {
    switch state {
    case .needsYou: Palette.amberText
    case .paused: Palette.inkTertiary
    case .atRest, .working: Palette.ink
    }
  }
}

/// Takes a buff dragged onto a tile, from + Buff, the Buffs panel or the welcome window.
private struct TileDropDelegate: DropDelegate {
  var folderID: Int64
  var host: AddBuffHost
  var verdict: BuffDropVerdict?
  var onAdd: (Buff) -> Void

  private var isAdding: Bool {
    if case .add = verdict { return true }
    return false
  }

  func dropEntered(info: DropInfo) {
    host.dropFolderID = folderID
  }

  func dropExited(info: DropInfo) {
    if host.dropFolderID == folderID { host.dropFolderID = nil }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: isAdding ? .copy : .forbidden)
  }

  func performDrop(info: DropInfo) -> Bool {
    host.dropFolderID = nil
    guard isAdding, let buff = host.draggedBuff else { return false }
    onAdd(buff)
    host.added = AddBuffHost.Added(buff: buff, folderID: folderID)
    return true
  }
}
