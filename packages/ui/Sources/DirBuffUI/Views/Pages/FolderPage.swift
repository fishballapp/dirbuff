import DirBuffCore
import SwiftUI

/// A folder's page, its sidebar row's: + Buff in the toolbar; the folder's icon, name and size, with
/// Show in Finder, its History and a menu that removes it; then one card per buff it wears, or the
/// buffs to put on it. A setting changes at once, and a toast offers Undo.
public struct FolderPage: View {
  public var state: FolderPageState
  public var binName: String
  public var actions: ShelfActions
  public var pageActions: FolderPageActions

  @State private var toast: SettingsToast?

  @Environment(\.addBuffHost) private var host

  public init(
    state: FolderPageState,
    binName: String = SystemBin.name,
    actions: ShelfActions = ShelfActions(),
    pageActions: FolderPageActions = FolderPageActions(),
    toast: SettingsToast? = nil
  ) {
    self.state = state
    self.binName = binName
    self.actions = actions
    self.pageActions = pageActions
    self._toast = State(initialValue: toast)
  }

  private var folder: FolderState { state.folder }

  private var wearsTemporary: Bool { state.cards.contains { $0.buff == .temporary } }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        head
        if state.cards.isEmpty && state.isMissing {
          MissingFolderNotice(folder: folder, actions: actions)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(Palette.amberTint, in: .rect(cornerRadius: Metrics.tileRadius))
            .overlay {
              RoundedRectangle(cornerRadius: Metrics.tileRadius)
                .strokeBorder(Palette.amberEdge, lineWidth: 1)
            }
        } else if state.cards.isEmpty {
          noBuffs
        } else {
          ForEach(state.cards) { card in
            BuffCardView(
              card: card,
              folder: folder,
              binName: binName,
              actions: actions,
              pageActions: pageActions,
              onChangeSettings: { change(to: $0, from: card.settings) }
            )
          }
        }
      }
      .padding(.top, 28)
      .padding(.horizontal, 40)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Palette.paper)
    .overlay(alignment: .bottom) {
      if let toast {
        settingsToast(toast)
          .padding(.bottom, 20)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.easeOut(duration: 0.2), value: toast)
    .task(id: toast?.id) {
      guard toast != nil else { return }
      // A newer toast cancels this wait, and must not be cleared by it.
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      toast = nil
    }
    .onChange(of: folder.id) {
      toast = nil
    }
    .onChange(of: wearsTemporary) {
      // Take Off forgets the settings, so there is nothing left for Undo to put back.
      if !wearsTemporary { toast = nil }
    }
    .navigationTitle(folder.name)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        addBuffButton
      }
    }
  }

  // MARK: - Toolbar

  private var addBuffButton: some View {
    Menu {
      FolderAddBuffMenuContent(
        folderName: folder.name,
        items: state.addBuffItems,
        onAddBuff: { actions.add($0, to: folder.id) }
      )
    } label: {
      Label("Buff", systemImage: "plus")
        .labelStyle(.titleAndIcon)
    }
    .menuIndicator(.hidden)
    .disabled(!state.canAddBuff || state.isMissing)
    .help("Add a buff to \(folder.name)")
  }

  // MARK: - Content

  private var head: some View {
    HStack(spacing: 18) {
      MarkedFolderIcon(path: folder.path, mark: folder.mark, size: .tile)
      VStack(alignment: .leading, spacing: 2) {
        Text(folder.name)
          .font(.title.bold())
          .foregroundStyle(Palette.ink)
          .lineLimit(1)
        Text(state.subtitle)
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
          .monospacedDigit()
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 12)
      HStack(spacing: 8) {
        if !state.isMissing {
          Button("Show in Finder") { actions.showInFinder(folder.id) }
        }
        GhostIconButton("History", systemImage: GhostIconButton.historySymbol) {
          pageActions.showHistory(folder.id)
        }
        Menu {
          Button("Remove from DirBuff…") { actions.removeFolder(folder.id) }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
      }
    }
    .padding(.horizontal, 4)
    .padding(.bottom, 4)
  }

  /// What the folder could wear, as pieces in a dashed zone: a click puts one on, and so does a
  /// buff dragged in.
  private var noBuffs: some View {
    let verdict = host.draggedBuff.map {
      BuffDropVerdict.of($0, on: folder, items: state.addBuffItems, mayClean: state.canAddBuff)
    }
    let isLit = host.dropFolderID == folder.id && verdict?.isAdding == true
    let zone = RoundedRectangle(cornerRadius: Metrics.tileRadius)
    return VStack(alignment: .leading, spacing: 14) {
      VStack(spacing: 4) {
        HStack(spacing: 6) {
          FolderPill(folder.name, path: folder.path)
          Text("wears no buffs yet")
        }
        .font(.headline)
        .foregroundStyle(Palette.ink)
        // Nothing goes on a folder on an unplugged drive, so its zone says why instead.
        Text(folder.unreachableReason.map { "\($0)." } ?? "Click or drag a buff to add it.")
          .foregroundStyle(Palette.inkSecondary)
        HStack(spacing: 10) {
          ForEach(Buff.allCases, id: \.self) { buff in
            let item = state.addBuffItems.first { $0.buff == buff }
            BuffPiece(buff, isEnabled: state.canAddBuff && item?.isEnabled == true) {
              actions.add(buff, to: folder.id)
            }
            .fixedSize()
            .help(item?.subtitle ?? "")
          }
        }
        .padding(.top, 14)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 30)
      .padding(.horizontal, 20)
      .background(isLit ? Palette.blueTint : .clear, in: zone)
      .overlay {
        if isLit {
          zone.strokeBorder(Palette.accentBlue, lineWidth: 1.5)
        } else {
          zone.strokeBorder(Palette.ruleStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
      }
      .buffDrop(on: folder.id, verdict: verdict) { actions.add($0, to: folder.id) }

      Text("DirBuff leaves \(folder.name) alone until you add a buff.")
        .font(.subheadline)
        .foregroundStyle(Palette.inkTertiary)
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, 4)
    }
  }

  // MARK: - Changing a setting

  /// Saves the new settings at once and offers Undo, which puts back `previous`.
  private func change(to settings: TemporarySettings, from previous: TemporarySettings) {
    pageActions.changeSettings(folder.id, settings)
    toast = SettingsToast(
      change: settingChange(from: previous, to: settings, binName: binName), previous: previous)
  }

  private func settingsToast(_ toast: SettingsToast) -> some View {
    Toast(actionTitle: "Undo") {
      pageActions.changeSettings(folder.id, toast.previous)
      self.toast = nil
    } message: {
      HStack(spacing: 10) {
        FolderPill(folder.name, path: folder.path)
        Text(toastLine(toast))
      }
    }
  }

  /// "older than 30 days now · nothing to clear tomorrow": what changed, then the card's new line.
  private func toastLine(_ toast: SettingsToast) -> String {
    guard let headline = state.cards.first(where: { $0.buff == .temporary })?.headline.text,
      let first = headline.first
    else { return toast.change }
    return "\(toast.change) · \(first.lowercased())\(headline.dropFirst())"
  }
}

/// The toast after a setting changed: what changed, and the settings Undo puts back.
public struct SettingsToast: Sendable, Equatable, Identifiable {
  public let id = UUID()
  /// "older than 30 days now".
  public var change: String
  public var previous: TemporarySettings

  public init(change: String, previous: TemporarySettings) {
    self.change = change
    self.previous = previous
  }
}
