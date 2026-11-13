import DirBuffKit
import SwiftUI

/// What the backup page asks the app to do.
public struct BackupPageActions {
  public var selectBackup: (String) -> Void = { _ in }
  /// An item chosen in a column; nil chooses the backup itself.
  public var select: (BackupItem?) -> Void = { _ in }
  /// The arrow keys.
  public var move: (BackupBrowserState.Direction) -> Void = { _ in }
  /// A timeline entry chosen: its backup, with the same file.
  public var showEntry: (TimelineEntry) -> Void = { _ in }
  /// Try Again on a column; nil for the list of backups.
  public var retry: (BackupPlace?) -> Void = { _ in }
  /// The fix a problem offers: sign in, enter the password, try again.
  public var fix: (RestoreProblem.Fix) -> Void = { _ in }
  /// Restore the item, from the backup shown, back where it was.
  public var restore: (BackupItem) -> Void = { _ in }
  /// Cancel the restore of the item in the backup shown.
  public var cancelRestore: (BackupPlace) -> Void = { _ in }
  /// Restore Folder… with the backup shown.
  public var restoreFolder: () -> Void = {}
  public var quickLook: (BackupItem) -> Void = { _ in }
  public var showInFinder: ([URL]) -> Void = { _ in }
  /// Downloads an item of a backup (by the backup's ID) to the URL a drop into Finder gives.
  /// A drag of an item (in the backup with this ID) starting: what writes it to the URL a
  /// drop into Finder gives, holding all it needs for as long as the drag lasts; nil when it
  /// can't be dragged now.
  public var prepareDragOut: (BackupItem, String) -> BackupFilePromise.Write? = { _, _ in nil }
  public var submitPassword: (String) -> Void = { _ in }
  public var cancelPassword: () -> Void = {}

  public init() {}
}

/// The backup page (Browse Backup…), pushed from Backup's card: the backups kept, the folder as the
/// one chosen saved it, opened as Finder's column view opens a folder, and the item selected
/// beside them, with what can be done with it. A file or folder that changed or went on this Mac
/// since that backup says so with a word.
public struct BackupPage: View {
  public var state: BackupBrowserState
  public var now: Date
  public var calendar: Calendar
  public var actions: BackupPageActions

  @FocusState private var isFocused: Bool

  public init(
    state: BackupBrowserState, now: Date, calendar: Calendar = .current,
    actions: BackupPageActions = BackupPageActions()
  ) {
    self.state = state
    self.now = now
    self.calendar = calendar
    self.actions = actions
  }

  public var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle(state.folderName)
      .navigationSubtitle(subtitle)
      .toolbar {
        FolderTitleIcon(path: state.folderPath)
        ToolbarItem(placement: .primaryAction) {
          GhostIconButton("Show in Finder", systemImage: GhostIconButton.finderSymbol) {
            actions.showInFinder([URL(fileURLWithPath: state.folderPath)])
          }
        }
      }
      .focusable()
      .focusEffectDisabled()
      .focused($isFocused)
      .onAppear { isFocused = true }
      .onKeyPress(.space) {
        guard let item = state.selectedItem, state.canQuickLook(item) else { return .ignored }
        actions.quickLook(item)
        return .handled
      }
      .onKeyPress(.upArrow) { key(.up) }
      .onKeyPress(.downArrow) { key(.down) }
      .onKeyPress(.leftArrow) { key(.left) }
      .onKeyPress(.rightArrow) { key(.right) }
      .sheet(item: passwordAsk) { ask in
        BackupPasswordAskSheet(
          ask: ask.value, onSubmit: actions.submitPassword, onCancel: actions.cancelPassword)
      }
  }

  private func key(_ direction: BackupBrowserState.Direction) -> KeyPress.Result {
    actions.move(direction)
    return .handled
  }

  private var passwordAsk: Binding<Identified<PasswordAsk>?> {
    Binding(
      get: { state.passwordAsk.map { Identified(value: $0) } },
      set: { if $0 == nil, state.passwordAsk != nil { actions.cancelPassword() } })
  }

  /// "Backup · 24 backups kept".
  private var subtitle: String {
    let count = state.keptBackups.count
    return count == 0
      ? "Backup" : "Backup · \(count == 1 ? "1 backup" : "\(count.formatted()) backups") kept"
  }

  @ViewBuilder
  private var content: some View {
    switch state.backups {
    case .loading:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Reading the backups…").foregroundStyle(Palette.inkTertiary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let problem):
      BackupProblemView(problem: problem) { fix in
        fix == .tryAgain ? actions.retry(nil) : actions.fix(fix)
      }
    case .loaded(let backups) where backups.isEmpty:
      FilesEmptyView(
        title: "No backup of \(state.folderName) has finished yet",
        detail:
          "Once the first is done, the folder as each backup saved it is here, to look through and restore from."
      )
    case .loaded(let backups):
      HStack(spacing: 0) {
        BackupsColumn(
          backups: backups, selectedID: state.backupID, now: now, calendar: calendar,
          onSelect: actions.selectBackup
        )
        .frame(width: 176)
        Palette.rule.frame(width: 1)
        columns
        Palette.rule.frame(width: 1)
        BackupPreviewPane(state: state, now: now, calendar: calendar, actions: actions)
          .frame(width: 290)
      }
    }
  }

  private var columns: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: 0) {
          ForEach(state.columns) { column in
            FolderColumn(
              column: column, isTop: column.place.path.isEmpty,
              listingSentence: state.listingSentence,
              restoring: state.restoringPaths(in: column.place.backupID), actions: actions
            )
            .equatable()
            .frame(width: 210)
            .id(column.id)
            Palette.rule.frame(width: 1)
          }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
      }
      .scrollIndicators(.automatic)
      .onAppear {
        if let last = state.columns.last?.id { proxy.scrollTo(last, anchor: .trailing) }
      }
      .onChange(of: state.columns.last?.id) { _, last in
        guard let last else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .trailing) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// A value made identifiable for `.sheet(item:)`, by its content.
private struct Identified<Value: Equatable>: Identifiable {
  var value: Value
  var id: Int { 0 }
}

/// The folder's icon beside the page's title. It sits on its own, with no glass behind it: next
/// to the back button macOS would otherwise draw both in one capsule, the icon off-centre in it.
struct FolderTitleIcon: ToolbarContent {
  var path: String

  var body: some ToolbarContent {
    if #available(macOS 26, *) {
      item.sharedBackgroundVisibility(.hidden)
    } else {
      item
    }
  }

  private var item: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Image(nsImage: folderIcon(atPath: path))
        .resizable()
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
  }
}

// MARK: - Backups

/// The first column: when each backup was saved, the newest first.
private struct BackupsColumn: View {
  var backups: [KeptBackup]
  var selectedID: String?
  var now: Date
  var calendar: Calendar
  var onSelect: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Backups")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Palette.inkTertiary)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
      ScrollView {
        LazyVStack(spacing: 1) {
          ForEach(Array(backups.enumerated()), id: \.element.id) { index, backup in
            row(backup, isLatest: index == 0)
          }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private func row(_ backup: KeptBackup, isLatest: Bool) -> some View {
    let isSelected = backup.id == selectedID
    return Button {
      onSelect(backup.id)
    } label: {
      VStack(alignment: .leading, spacing: 1) {
        Text(versionMoment(backup.savedAt, now: now, calendar: calendar))
          .foregroundStyle(Palette.ink)
        if isLatest {
          Text("Latest backup")
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
        }
      }
      .font(.callout)
      .monospacedDigit()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(isSelected ? Palette.blueTint : .clear, in: .rect(cornerRadius: 6))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

// MARK: - Folder columns

/// One folder of the backup shown: its items by name, or why they aren't here yet.
/// Equal when what it draws is: a restore's progress, which changes every second, isn't among
/// it, so a column of tens of thousands of rows isn't drawn again for it.
private struct FolderColumn: View, Equatable {
  var column: BackupColumn
  var isTop: Bool
  var listingSentence: String
  /// The paths of its backup being restored.
  var restoring: Set<String>
  var actions: BackupPageActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.column == rhs.column && lhs.isTop == rhs.isTop && lhs.listingSentence == rhs.listingSentence
      && lhs.restoring == rhs.restoring
  }

  var body: some View {
    Group {
      switch column.listing {
      case .loaded(let items) where !items.isEmpty:
        rows(items)
      default:
        notice
          .contentShape(.rect)
          .onTapGesture(perform: selectFolder)
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  /// A click on the column's empty space selects the folder it lists, as Finder does.
  private func selectFolder() {
    actions.select(isTop ? nil : BackupItem(path: column.place.path, kind: .folder))
  }

  /// Why the column has no rows: it is loading, it couldn't be listed, or the folder is empty.
  @ViewBuilder
  private var notice: some View {
    switch column.listing {
    case .loading:
      VStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(listingSentence)
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .combine)
    case .failed(let problem):
      BackupProblemView(problem: problem, isCompact: true) { fix in
        fix == .tryAgain ? actions.retry(column.place) : actions.fix(fix)
      }
    case .loaded:
      Text("Empty folder")
        .font(.subheadline)
        .foregroundStyle(Palette.inkTertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// The empty space is a layer behind the rows, as tall as the column at least, and never a
  /// gesture on something that holds them: a click on a row is the row's alone, so nothing
  /// takes its selection back when the mouse comes up.
  private func rows(_ items: [BackupItem]) -> some View {
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 1) {
            ForEach(items) { item in
              BackupItemRow(
                item: item, place: column.place,
                selection: column.selectedPath == item.path
                  ? (column.isActive ? .active : .onTheWay) : nil,
                isRestoring: restoring.contains(item.path),
                actions: actions
              )
              .id(item.path)
            }
          }
          .padding(6)
          .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
          .background {
            Color.clear
              .contentShape(.rect)
              .onTapGesture(perform: selectFolder)
          }
        }
        .onAppear {
          if let selected = column.selectedPath { proxy.scrollTo(selected, anchor: .center) }
        }
      }
    }
  }
}

/// A file or folder in a column: its icon and name, a quiet word when it has changed or gone on
/// this Mac since that backup, and a chevron on a folder. It drags out to Finder.
private struct BackupItemRow: View {
  enum Selection {
    /// The item selected.
    case active
    /// A folder on the way to it, in an earlier column.
    case onTheWay
  }

  var item: BackupItem
  var place: BackupPlace
  var selection: Selection?
  var isRestoring: Bool
  var actions: BackupPageActions

  var body: some View {
    HStack(spacing: 6) {
      Image(nsImage: BackupItemIcon.image(for: item))
        .resizable()
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
      Text(item.name)
        .foregroundStyle(Palette.ink)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      if isRestoring {
        ProgressView().controlSize(.mini)
      }
      if let word = item.sinceThen.flatMap(Self.word) {
        Text(word)
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
          .fixedSize()
      }
      if item.isFolder {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(Palette.quiet)
          .accessibilityHidden(true)
      }
    }
    .font(.callout)
    .padding(.horizontal, 8)
    .frame(height: 24)
    .background(background, in: .rect(cornerRadius: 5))
    .overlay {
      BackupItemDragSource(
        item: item, onSelect: { actions.select(item) },
        prepare: { [prepareDragOut = actions.prepareDragOut, backupID = place.backupID] in
          prepareDragOut(item, backupID)
        })
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAddTraits(selection == .active ? .isSelected : [])
    .accessibilityAction { actions.select(item) }
  }

  private var background: Color {
    switch selection {
    case .active: Palette.blueTint
    case .onTheWay: Color.primary.opacity(0.07)
    case nil: .clear
    }
  }

  /// The mark: a word, never a colour alone.
  static func word(_ sinceThen: BackupItem.SinceThen) -> String? {
    switch sinceThen {
    case .deleted: "Deleted"
    case .changed: "Changed"
    // Nothing is known: no word, and the preview says why.
    case .unknown: nil
    }
  }
}

// MARK: - Problems

/// Why something couldn't be listed: the sentence, and its one fix as a button.
private struct BackupProblemView: View {
  var problem: RestoreProblem
  var isCompact = false
  var onFix: (RestoreProblem.Fix) -> Void

  var body: some View {
    VStack(spacing: 10) {
      Text(problem.message)
        .font(isCompact ? .callout : .body)
        .foregroundStyle(Palette.inkSecondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      if let title = problem.fix.title {
        Button(title) { onFix(problem.fix) }
          .controlSize(isCompact ? .small : .regular)
      }
    }
    .padding(isCompact ? 16 : 32)
    .frame(maxWidth: isCompact ? .infinity : 440, maxHeight: .infinity)
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Password

/// The backup's password, asked for when this Mac's Keychain doesn't open it. It is held until
/// the page closes and kept nowhere.
public struct BackupPasswordAskSheet: View {
  var ask: PasswordAsk
  var onSubmit: (String) -> Void
  var onCancel: () -> Void

  @State private var password: String

  public init(
    ask: PasswordAsk, password: String = "", onSubmit: @escaping (String) -> Void = { _ in },
    onCancel: @escaping () -> Void = {}
  ) {
    self.ask = ask
    self.onSubmit = onSubmit
    self.onCancel = onCancel
    self._password = State(initialValue: password)
  }

  public var body: some View {
    RestoreSheetShell(sentences: [ask.explanation]) {
      Text("The backup has a password")
    } content: {
      RestorePasswordForm(ask: ask, password: $password) { onSubmit(password) }
    } buttons: {
      Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
      Button("Open Backup") { onSubmit(password) }
        .keyboardShortcut(.defaultAction)
        .disabled(password.isEmpty || ask.isChecking)
    }
  }
}
