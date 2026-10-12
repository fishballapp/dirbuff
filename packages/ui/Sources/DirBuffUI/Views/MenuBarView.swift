import AppKit
import SwiftUI

/// The menu-bar window: what goes next, the folders, recent runs, and a way out.
public struct MenuBarView: View {
  public var state: MenuBarState
  public var onTurnOnFinderExtension: () -> Void
  public var onSelectFolder: (FolderSummary) -> Void
  public var onUndo: (RecentRun) -> Void
  public var onOpen: () -> Void
  public var onQuit: () -> Void
  public var onBuy: () -> Void
  public var onEnterKey: () -> Void
  public var onCheckLicence: () -> Void

  public init(
    state: MenuBarState,
    onTurnOnFinderExtension: @escaping () -> Void = {},
    onSelectFolder: @escaping (FolderSummary) -> Void = { _ in },
    onUndo: @escaping (RecentRun) -> Void = { _ in },
    onOpen: @escaping () -> Void = {},
    onQuit: @escaping () -> Void = {},
    onBuy: @escaping () -> Void = {},
    onEnterKey: @escaping () -> Void = {},
    onCheckLicence: @escaping () -> Void = {}
  ) {
    self.state = state
    self.onTurnOnFinderExtension = onTurnOnFinderExtension
    self.onSelectFolder = onSelectFolder
    self.onUndo = onUndo
    self.onOpen = onOpen
    self.onQuit = onQuit
    self.onBuy = onBuy
    self.onEnterKey = onEnterKey
    self.onCheckLicence = onCheckLicence
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if state.isFinderExtensionOff {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.circle")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text("Finder extension is off")
          Spacer()
          Button("Turn On", action: onTurnOnFinderExtension)
            .controlSize(.small)
        }
        .font(.callout)
      }

      VStack(alignment: .leading, spacing: 2) {
        Text(state.headline).font(.headline).monospacedDigit()
        Text(state.subheadline)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }

      if state.hasNoFolders {
        if state.invitesFirstFolder {
          Text("Right-click a folder in Finder and choose Add to DirBuff… to start.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        if !state.forecast.isEmpty {
          ForecastList(groups: state.forecast).padding(.horizontal, -8)
        }
        section("Folders") {
          ForEach(state.folders) { folder in
            Button {
              onSelectFolder(folder)
            } label: {
              folderRow(folder)
            }
            .buttonStyle(MenuRowStyle())
          }
        }
        if !state.recentRuns.isEmpty {
          section("Recent") {
            ForEach(state.recentRuns) { run in
              RecentRunRow(run: run, onPutBack: onUndo)
            }
          }
        }
      }

      Divider()
      VStack(spacing: 0) {
        if let line = state.licenceLine {
          Button(action: line.action.isPurchase ? onBuy : onCheckLicence) {
            HStack {
              Text(line.action.title)
              Spacer()
              Text(line.text).foregroundStyle(.secondary)
            }
          }
          if line.action.isPurchase {
            Button("Enter Licence Key…", action: onEnterKey)
          }
        }
        Button("Open DirBuff", action: onOpen)
        Button("Quit DirBuff", action: onQuit)
          .keyboardShortcut("q")
      }
      .buttonStyle(MenuRowStyle())
      .padding(.horizontal, -8)
    }
    .padding(14)
    .frame(width: 340)
  }

  private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
      VStack(spacing: 0, content: rows).padding(.horizontal, -8)
    }
  }

  private func folderRow(_ folder: FolderSummary) -> some View {
    HStack(spacing: 8) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
        .resizable()
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
      Text(folder.name).lineLimit(1)
      Spacer()
      Text(folder.distanceToGoing)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .help(folder.rules)
  }
}
