import DirBuffCore
import SwiftUI

/// A folder's page, pushed over the shelf: back (⌘[), the folder's name as a pop-up that opens the
/// folder switcher, and + Buff in the toolbar; the folder's icon, name and size; then one card per
/// buff it wears. A setting changes at once, and a toast offers Undo.
public struct FolderPage: View {
  public var state: FolderPageState
  public var binName: String
  public var actions: ShelfActions
  public var pageActions: FolderPageActions

  @State private var isSwitcherOpen: Bool
  @State private var toast: SettingsToast?

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
    self._isSwitcherOpen = State(initialValue: false)
    self._toast = State(initialValue: toast)
  }

  private var folder: FolderState { state.folder }

  private var wearsTemporary: Bool { state.cards.contains { $0.buff == .temporary } }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        head
        if state.cards.isEmpty {
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
      isSwitcherOpen = false
    }
    .onChange(of: wearsTemporary) {
      // Take Off forgets the settings, so there is nothing left for Undo to put back.
      if !wearsTemporary { toast = nil }
    }
    .modifier(SwitcherTitle(name: folder.name))
    .toolbar {
      ToolbarItem(placement: .navigation) {
        switcherButton
      }
      ToolbarItem(placement: .primaryAction) {
        addBuffButton
      }
    }
    .background {
      // ⌘[ goes back to every folder, as the switcher's foot says.
      Button("All Folders", action: pageActions.showAllFolders)
        .keyboardShortcut("[", modifiers: .command)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  // MARK: - Toolbar

  private var switcherButton: some View {
    Button {
      isSwitcherOpen.toggle()
    } label: {
      HStack(spacing: 7) {
        Text(folder.name)
          .font(.title3.bold())
          .foregroundStyle(Palette.ink)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Palette.inkSecondary)
      }
      .padding(.horizontal, 4)
    }
    .accessibilityLabel("Switch folder, now \(folder.name)")
    .popover(isPresented: $isSwitcherOpen, arrowEdge: .bottom) {
      FolderSwitcher(folders: state.switcher, currentID: folder.id) { id in
        isSwitcherOpen = false
        if id != folder.id { pageActions.openFolder(id) }
      }
    }
  }

  private var addBuffButton: some View {
    Menu {
      FolderAddBuffMenuContent(
        folderName: folder.name,
        items: state.addBuffItems,
        onAddBuff: { actions.addBuff(folder.id, $0) }
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
      if !state.isMissing {
        Button("Show in Finder") { actions.showInFinder(folder.id) }
      }
    }
    .padding(.horizontal, 4)
    .padding(.bottom, 4)
  }

  private var noBuffs: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        FolderPill(folder.name, path: folder.path)
        Text("wears no buffs")
      }
      .font(.headline)
      .foregroundStyle(Palette.ink)
      Text("Add one with + Buff.")
        .foregroundStyle(Palette.inkSecondary)
    }
    .padding(.horizontal, 4)
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

  /// "older than 30 days now · nothing goes tomorrow": what changed, then the card's new line.
  private func toastLine(_ toast: SettingsToast) -> String {
    guard let headline = state.cards.first(where: { $0.buff == .temporary })?.headline.text,
      let first = headline.first
    else { return toast.change }
    return "\(toast.change) · \(first.lowercased())\(headline.dropFirst())"
  }
}

/// Names the window after the folder while the switcher's pop-up stands in for the toolbar's
/// title. Before macOS 15 the toolbar can't drop its title, so the window goes untitled instead of
/// naming the folder twice.
private struct SwitcherTitle: ViewModifier {
  var name: String

  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content
        .navigationTitle(name)
        .toolbar(removing: .title)
    } else {
      content.navigationTitle("")
    }
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
