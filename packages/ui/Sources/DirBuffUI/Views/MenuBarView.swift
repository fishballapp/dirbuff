import AppKit
import SwiftUI

/// The menu-bar popover: the status sentence with the clean-up schedule, a callout for each folder
/// that needs the user (or the clean-up running now), and the licence at the foot. The
/// app hosts it in one item of a status menu, so an auto-hidden menu bar stays shown while it's open.
public struct MenuBarView: View {
  public var state: PopoverState
  public var onFix: (_ folderID: Int64, Fix) -> Void
  public var onOpen: () -> Void
  public var onSettings: () -> Void
  public var onBuy: () -> Void
  public var onCheckLicence: () -> Void

  public init(
    state: PopoverState,
    onFix: @escaping (_ folderID: Int64, Fix) -> Void = { _, _ in },
    onOpen: @escaping () -> Void = {},
    onSettings: @escaping () -> Void = {},
    onBuy: @escaping () -> Void = {},
    onCheckLicence: @escaping () -> Void = {}
  ) {
    self.state = state
    self.onFix = onFix
    self.onOpen = onOpen
    self.onSettings = onSettings
    self.onBuy = onBuy
    self.onCheckLicence = onCheckLicence
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let run = state.run {
        runSection(run)
      } else {
        VStack(alignment: .leading, spacing: 2) {
          Text(state.headline).font(.headline)
          if let subheadline = state.subheadline {
            Text(subheadline).font(.subheadline).foregroundStyle(.secondary)
          }
        }
      }

      ForEach(state.needsYou) { item in
        callout(item).padding(.top, 10)
      }

      foot.padding(.top, 12)
    }
    .padding(14)
    .frame(width: 340, alignment: .leading)
  }

  /// The clean-up running now. Every line has a fixed height and truncates at its tail, and the
  /// figures are tabular, so the item names changing don't move anything.
  private func runSection(_ run: PopoverRun) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Clearing")
        FolderPill(run.folderName, path: run.path)
      }
      .font(.headline)
      VStack(alignment: .leading, spacing: 4) {
        Text(run.current ?? " ")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(height: 16, alignment: .leading)
        Capsule()
          .fill(Palette.ruleStrong)
          .frame(height: 5)
          .overlay(alignment: .leading) {
            GeometryReader { bar in
              Capsule()
                .fill(Palette.accentBlue)
                .frame(width: bar.size.width * run.fraction)
            }
          }
        Text(run.counts ?? " ")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .lineLimit(1)
          .frame(height: 16, alignment: .leading)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(state.headline)
    .accessibilityValue(run.counts ?? "")
  }

  /// Spans the popover's full width, edge to edge. Its headline names the folder in a pill, so the
  /// name reads as a folder.
  private func callout(_ item: NeedsYou) -> some View {
    HStack(alignment: .top, spacing: 10) {
      NeedsYouBadge(size: 20)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          Text(item.lead)
          FolderPill(item.folderName, path: item.path)
        }
        .font(.headline)
        .foregroundStyle(Palette.amberText)
        Text(item.reason)
          .font(.subheadline)
          .foregroundStyle(Palette.inkSecondary)
        Button(item.fix.title) { onFix(item.id, item.fix) }
          .buttonStyle(.borderedProminent)
          .tint(Palette.accentBlue)
          .controlSize(.small)
          .padding(.top, 4)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.amberTint)
    .overlay(alignment: .top) { Palette.amberEdge.frame(height: 1) }
    .overlay(alignment: .bottom) { Palette.amberEdge.frame(height: 1) }
    .padding(.horizontal, -14)
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
