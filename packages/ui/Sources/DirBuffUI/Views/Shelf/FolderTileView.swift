import AppKit
import SwiftUI

/// One folder on the shelf: its 64 pt Finder icon and mark in a Well band on top, and one row
/// beneath for each buff it wears.
struct FolderTileView: View {
  var folder: FolderState
  var addBuffItems: [AddBuffItem]
  var canAddBuff: Bool
  var actions: ShelfActions
  var onOpen: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var isHovered = false

  var body: some View {
    VStack(spacing: 0) {
      folderBand
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

  private var borderColor: Color {
    if folder.isNeedingYou { return Palette.amberEdge }
    return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.14)
  }

  private var borderWidth: CGFloat {
    folder.isNeedingYou ? 1 : 0.5
  }

  private var folderBand: some View {
    Button(action: onOpen) {
      VStack(spacing: 0) {
        MarkedFolderIcon(path: folder.path, mark: folder.mark, size: .tile)
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
        if case .paused(let reason) = row.state {
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
