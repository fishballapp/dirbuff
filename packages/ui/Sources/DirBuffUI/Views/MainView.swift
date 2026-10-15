import AppKit
import DirBuffCore
import DirBuffKit
import SwiftUI

/// DirBuff's main window: Overview and the listed folders in the sidebar, the selection beside it.
public struct MainView: View {
  public var state: MainState
  @Binding public var selection: MainSelection?
  public var binName: String
  public var onAddFolder: () -> Void
  public var onRemoveFolder: (Int64) -> Void
  public var onSetTemporary: (Int64, Bool) -> Void
  public var onChangeSettings: (Int64, TemporarySettings) -> Void
  public var onPutBack: (RecentRun) -> Void
  public var onBuy: () -> Void
  public var onEnterKey: () -> Void
  public var onCheckLicence: () -> Void

  public init(
    state: MainState,
    selection: Binding<MainSelection?>,
    binName: String = SystemBin.name,
    onAddFolder: @escaping () -> Void = {},
    onRemoveFolder: @escaping (Int64) -> Void = { _ in },
    onSetTemporary: @escaping (Int64, Bool) -> Void = { _, _ in },
    onChangeSettings: @escaping (Int64, TemporarySettings) -> Void = { _, _ in },
    onPutBack: @escaping (RecentRun) -> Void = { _ in },
    onBuy: @escaping () -> Void = {},
    onEnterKey: @escaping () -> Void = {},
    onCheckLicence: @escaping () -> Void = {}
  ) {
    self.state = state
    self._selection = selection
    self.binName = binName
    self.onAddFolder = onAddFolder
    self.onRemoveFolder = onRemoveFolder
    self.onSetTemporary = onSetTemporary
    self.onChangeSettings = onChangeSettings
    self.onPutBack = onPutBack
    self.onBuy = onBuy
    self.onEnterKey = onEnterKey
    self.onCheckLicence = onCheckLicence
  }

  public var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
  }

  @ViewBuilder
  private var sidebar: some View {
    List(selection: $selection) {
      Label("Overview", systemImage: "calendar")
        .tag(MainSelection.overview)

      Section("Folders") {
        ForEach(state.folders) { folder in
          folderRow(folder)
            .tag(MainSelection.folder(folder.id))
            .contextMenu {
              Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
              }
              Button("Remove from DirBuff") {
                onRemoveFolder(folder.id)
              }
            }
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      VStack(spacing: 0) {
        if let line = state.overview.licenceLine {
          Divider()
          licence(line)
        }
        Divider()
        HStack(spacing: 4) {
          Button(action: onAddFolder) {
            Image(systemName: "plus")
              .frame(width: 20, height: 20)
              .contentShape(.rect)
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .help("Add a folder")

          Button(action: removeSelectedFolder) {
            Image(systemName: "minus")
              .frame(width: 20, height: 20)
              .contentShape(.rect)
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .disabled(!isFolderSelected)
          .help("Remove from DirBuff")

          Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
      }
    }
  }

  private func licence(_ line: LicenceLine) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(line.text, systemImage: line.isWarning ? "exclamationmark.circle" : "clock")
        .foregroundStyle(.secondary)
      Button(action: line.action.isPurchase ? onBuy : onCheckLicence) {
        Text(line.action.title).frame(maxWidth: .infinity)
      }
      if line.action.isPurchase {
        Button(action: onEnterKey) {
          Text("Enter Licence Key…").frame(maxWidth: .infinity)
        }
        .buttonStyle(.link)
      }
    }
    .font(.callout)
    .padding(12)
  }

  private var isFolderSelected: Bool {
    if case .folder = selection {
      return true
    }
    return false
  }

  private func removeSelectedFolder() {
    if case .folder(let id) = selection {
      onRemoveFolder(id)
    }
  }

  private func folderRow(_ folder: MainFolder) -> some View {
    HStack(spacing: 8) {
      Image(nsImage: folderIcon(atPath: folder.path))
        .resizable()
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(folder.name)
          .lineLimit(1)
        Text(folder.distanceToGoing)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .lineLimit(1)
      }
    }
  }

  @ViewBuilder
  private var detail: some View {
    if case .folder(let id) = selection,
      let folder = state.folders.first(where: { $0.id == id })
    {
      FolderDetailView(
        folder: folder,
        binName: binName,
        licenceRefusal: state.licenceRefusal,
        buyTitle: state.buyTitle,
        onSetTemporary: { onSetTemporary(folder.id, $0) },
        onChangeSettings: { onChangeSettings(folder.id, $0) },
        onBuy: onBuy
      )
    } else {
      overviewDetail
    }
  }

  @ViewBuilder
  private var overviewDetail: some View {
    if state.folders.isEmpty {
      Text("Add a folder with + or right-click one in Finder and choose Add to DirBuff…")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 2) {
            Text(state.overview.headline)
              .font(.title3)
              .fontWeight(.semibold)
              .monospacedDigit()
            Text(state.overview.subheadline)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }

          if !state.overview.forecast.isEmpty {
            ForecastList(groups: state.overview.forecast)
              .padding(.horizontal, -8)
          }

          if !state.overview.recentRuns.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
              Text("Recent")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
              VStack(spacing: 0) {
                ForEach(state.overview.recentRuns) { run in
                  RecentRunRow(run: run, onPutBack: onPutBack)
                }
              }
              .padding(.horizontal, -8)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
      }
    }
  }
}
