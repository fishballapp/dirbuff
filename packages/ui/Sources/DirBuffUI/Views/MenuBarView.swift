import AppKit
import SwiftUI

/// The menu-bar popover: the status sentence, a callout for each folder that needs the user (or a
/// bar while something clears), the folders with a line per buff, and the licence at the foot. The
/// app hosts it in one item of a status menu, so an auto-hidden menu bar stays shown while it's open.
public struct MenuBarView: View {
  public var state: PopoverState
  public var onFix: (Fix) -> Void
  public var onSelectFolder: (FolderState) -> Void
  public var onOpen: () -> Void
  public var onSettings: () -> Void
  public var onBuy: () -> Void
  public var onCheckLicence: () -> Void

  public init(
    state: PopoverState,
    onFix: @escaping (Fix) -> Void = { _ in },
    onSelectFolder: @escaping (FolderState) -> Void = { _ in },
    onOpen: @escaping () -> Void = {},
    onSettings: @escaping () -> Void = {},
    onBuy: @escaping () -> Void = {},
    onCheckLicence: @escaping () -> Void = {}
  ) {
    self.state = state
    self.onFix = onFix
    self.onSelectFolder = onSelectFolder
    self.onOpen = onOpen
    self.onSettings = onSettings
    self.onBuy = onBuy
    self.onCheckLicence = onCheckLicence
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text(state.headline).font(.headline)
        if let subheadline = state.subheadline {
          Text(subheadline).font(.subheadline).foregroundStyle(.secondary)
        }
      }

      ForEach(state.needsYou) { item in
        callout(item).padding(.top, 10)
      }
      if state.needsYou.isEmpty && state.isClearing {
        Capsule()
          .fill(Palette.accentBlue)
          .frame(height: 5)
          .padding(.top, 10)
          .accessibilityLabel("Clearing now")
      }

      if !state.folders.isEmpty {
        Text("Folders")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
          .padding(.top, 14)
          .padding(.horizontal, 8)
        VStack(spacing: 0) {
          ForEach(state.folders) { folder in
            folderRow(folder)
          }
        }
        .padding(.horizontal, -8)
        .padding(.top, 2)
      }

      foot.padding(.top, 12)
    }
    .padding(14)
    .frame(width: 340, alignment: .leading)
  }

  /// Spans the popover's content width. Its headline names the folder in a pill, so the name reads
  /// as a folder.
  private func callout(_ item: NeedsYou) -> some View {
    HStack(alignment: .top, spacing: 10) {
      NeedsYouBadge(size: 20)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          folderPill(item)
          Text("isn't cleared")
        }
        .font(.headline)
        .foregroundStyle(Palette.amberText)
        Text(item.reason)
          .font(.subheadline)
          .foregroundStyle(Palette.inkSecondary)
        Button(item.fix.title) { onFix(item.fix) }
          .buttonStyle(.borderedProminent)
          .tint(Palette.accentBlue)
          .controlSize(.small)
          .padding(.top, 4)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.amberTint, in: .rect(cornerRadius: 10))
  }

  private func folderPill(_ item: NeedsYou) -> some View {
    HStack(spacing: 4) {
      Image(nsImage: folderIcon(atPath: item.path))
        .resizable()
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
      Text(item.folderName).lineLimit(1)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 1)
    .background(Palette.amberText.opacity(0.12), in: .capsule)
  }

  private func folderRow(_ folder: FolderState) -> some View {
    Button {
      onSelectFolder(folder)
    } label: {
      HStack(alignment: .top, spacing: 8) {
        ZStack(alignment: .bottomLeading) {
          Image(nsImage: folderIcon(atPath: folder.path))
            .resizable()
            .frame(width: 20, height: 20)
          if let mark = folder.mark {
            Mark(mark, size: 12).offset(x: -3, y: 3)
          }
        }
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(folder.name).lineLimit(1)
          ForEach(folder.buffs) { row in
            buffLine(row)
          }
        }
      }
    }
    .buttonStyle(MenuRowStyle())
  }

  /// One buff on a folder's row: its symbol and what it's doing, in numbers.
  private func buffLine(_ row: BuffRow) -> some View {
    HStack(spacing: 5) {
      BuffSymbol(row.buff, width: 16)
        .foregroundStyle(symbolColor(row.state))
      Text(row.status)
        .font(.subheadline)
        .lineLimit(1)
        .foregroundStyle(lineColor(row.state))
    }
  }

  private func symbolColor(_ buffState: BuffState) -> Color {
    guard state.isCleaning else { return Palette.inkTertiary }
    return buffState == .paused ? Palette.quiet : Palette.ink
  }

  private func lineColor(_ buffState: BuffState) -> Color {
    guard state.isCleaning else { return Palette.inkTertiary }
    switch buffState {
    case .needsYou: return Palette.amberText
    case .paused: return Palette.inkTertiary
    case .atRest, .working, .takenOff: return Palette.inkSecondary
    }
  }

  /// The licence line and the button that acts on it, on one row with the app's own buttons.
  private var foot: some View {
    VStack(alignment: .leading, spacing: 0) {
      Divider()
      HStack(spacing: 8) {
        if let foot = state.foot {
          HStack(spacing: 0) {
            Text(foot.lead).fontWeight(.semibold)
            Text(foot.rest).foregroundStyle(.secondary)
          }
          .font(.callout)
          .lineLimit(1)
        }
        Spacer(minLength: 0)
        if let foot = state.foot {
          footButton(foot)
        }
        Button("Open DirBuff", action: onOpen).controlSize(.small)
        Button(action: onSettings) {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
        .help("Settings…")
        .accessibilityLabel("Settings…")
      }
      .padding(.top, 8)
    }
  }

  @ViewBuilder
  private func footButton(_ foot: PopoverFoot) -> some View {
    let button = Button(foot.buttonTitle, action: foot.isPurchase ? onBuy : onCheckLicence)
      .controlSize(.small)
    if foot.isWarning {
      button.buttonStyle(.borderedProminent)
    } else {
      button.buttonStyle(.bordered)
    }
  }
}
