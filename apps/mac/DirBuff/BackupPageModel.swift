import AppKit
import DirBuffKit
import DirBuffUI
import Foundation
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "restore")

/// The backup page of one folder while it is open: lists each folder of a backup from Google
/// Drive when it is opened, and keeps every listing until the page closes (a backup never
/// changes); reads a file's history from the database; restores, previews and drags items out.
/// The backup's password, when this Mac's Keychain doesn't open it, is held here and nowhere
/// else, from when it is checked until the page closes. A restore or a drag already under way
/// keeps its own copy until it ends, and Restore Folder… its own until its sheet closes or, hidden,
/// its restore ends.
@MainActor @Observable
final class BackupPageModel {
  private(set) var state: BackupBrowserState
  /// The file Quick Look shows, downloaded into the page's own temporary folder.
  var quickLookURL: URL?

  let folderID: Int64
  @ObservationIgnored private let appModel: AppModel
  @ObservationIgnored private var password: String?
  @ObservationIgnored private var listings: [BackupPlace: Task<Void, Never>] = [:]
  /// The restore running for each item, by run: one cancelled is dropped at once, and its task,
  /// which ends only once restic has, touches nothing when it does.
  @ObservationIgnored private var restores: [BackupPlace: (run: UUID, task: Task<Void, Never>)] =
    [:]
  @ObservationIgnored private var quickLook: Task<Void, Never>?
  /// The folder the last preview was downloaded into, removed when the next starts.
  @ObservationIgnored private var previewFolder: URL?
  @ObservationIgnored private var passwordCheck: Task<Void, Never>?
  /// What asked for the password, done again once it opens the backup.
  @ObservationIgnored private var afterPassword: [@MainActor () -> Void] = []
  @ObservationIgnored private var isClosed = false
  /// Where Quick Look's downloads go; removed when the page closes.
  @ObservationIgnored private let quickLookFolder = BackupPageModel.quickLookRoot
    .appendingPathComponent(UUID().uuidString)

  /// Every page's Quick Look folder is in here. What a page left when DirBuff quit goes at the
  /// next launch (`clearQuickLookLeftovers`), never while a page may be showing one of them.
  private static let quickLookRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("DirBuff Quick Look")

  /// At launch, before any page opens: the Quick Look downloads a quit left behind.
  static func clearQuickLookLeftovers() {
    try? FileManager.default.removeItem(at: quickLookRoot)
  }

  init(appModel: AppModel, folderID: Int64, folderPath: String) {
    self.appModel = appModel
    self.folderID = folderID
    state = BackupBrowserState(
      folderName: URL(fileURLWithPath: folderPath).lastPathComponent, folderPath: folderPath)
  }

  private var backup: BackupBuff { appModel.backup }

  // MARK: Loading

  /// The backups kept, from the database; asked of Drive only when it doesn't know them yet.
  func loadBackups() async {
    state.isFolderAway = !backup.isFolderOnThisMac(folderID: folderID)
    do {
      let kept = try await backup.keptBackups(folderID: folderID, password: password)
      state.show(.loaded(kept))
      loadHistory()
      loadWanted()
    } catch is CancellationError {
    } catch {
      state.show(.failed(await describe(error, while: .listing)))
    }
  }

  /// After a backup: the new backup joins the list, and the timelines are read again.
  func refresh() async {
    guard case .loaded = state.backups else { return }
    state.histories = [:]
    await loadBackups()
  }

  /// Lists the folders the columns have opened that haven't been asked for.
  private func loadWanted() {
    guard !isClosed else { return }
    for place in state.listingsWanted where listings[place] == nil {
      state.listings[place] = .loading
      list(place)
    }
  }

  /// Lists `place`, leaving what it shows until the answer comes.
  private func list(_ place: BackupPlace) {
    guard !isClosed, let kept = state.keptBackups.first(where: { $0.id == place.backupID }) else {
      return
    }
    let (backup, folderID, password) = (backup, folderID, password)
    listings[place] = Task {
      do {
        let items = try await backup.items(
          in: place.path, of: kept, folderID: folderID, password: password)
        state.didList(place, items)
      } catch is CancellationError {
        state.listings[place] = nil
      } catch {
        state.listings[place] = .failed(await describe(error, while: .listing))
      }
      listings[place] = nil
      loadWanted()
    }
  }

  /// The selected file's history, from the database.
  private func loadHistory() {
    guard let selection = state.selection, !selection.isFolder,
      state.histories[selection.path] == nil
    else { return }
    do {
      state.histories[selection.path] = try backup.history(
        of: selection.path, folderID: folderID)
    } catch {
      logger.error("Couldn't read a history: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// The problem for `error`. One about the password asks for it, and `retry` is done again
  /// once the password opens the backup; one about the account is noted, so the folders say so
  /// too.
  private func describe(
    _ error: any Error, while subject: RestoreProblem.Subject,
    retry: (@MainActor () -> Void)? = nil
  ) async -> RestoreProblem {
    switch error {
    case BackupBuff.Failure.passwordNeeded, BackupBuff.Failure.passwordDoesNotOpen:
      password = nil
      if let retry { afterPassword.append(retry) }
      if !isClosed, state.passwordAsk == nil {
        state.passwordAsk = PasswordAsk(macName: "This Mac", isForThisMac: true)
      }
    default:
      logger.error("The backup page: \(String(describing: error), privacy: .public)")
      await appModel.noteDriveProblem(error)
    }
    return RestoreProblem(error, while: subject)
  }

  // MARK: Choosing

  func selectBackup(_ id: String) {
    state.selectBackup(id)
    loadWanted()
  }

  func select(_ item: BackupItem?) {
    state.select(item)
    loadHistory()
    loadWanted()
  }

  func move(_ direction: BackupBrowserState.Direction) {
    state.move(direction)
    loadHistory()
    loadWanted()
  }

  func show(_ entry: TimelineEntry) {
    state.show(entry)
    loadWanted()
  }

  /// Try Again on a column, or on the list of backups.
  func retry(_ place: BackupPlace?) {
    guard let place else {
      state.show(.loading)
      Task { await loadBackups() }
      return
    }
    state.listings[place] = nil
    loadWanted()
  }

  func fix(_ fix: RestoreProblem.Fix) {
    switch fix {
    case .enterPassword:
      state.passwordAsk = PasswordAsk(macName: "This Mac", isForThisMac: true)
    case .signIn, .chooseAccount:
      appModel.askToSignIn(.signInAgain)
    case .tryAgain:
      retryFailed()
    case .none, .chooseFolder:
      break
    }
  }

  /// Asks again for everything that failed.
  private func retryFailed() {
    if case .failed = state.backups {
      retry(nil)
      return
    }
    for (place, listing) in state.listings {
      if case .failed = listing { state.listings[place] = nil }
    }
    loadWanted()
  }

  // MARK: The password

  /// Checks the password typed against the backup, whatever asked for it. One that opens it is
  /// kept until the page closes, and what asked is done again; a wrong one is asked for again.
  func submitPassword(_ typed: String) {
    state.passwordAsk = PasswordAsk(macName: "This Mac", isChecking: true, isForThisMac: true)
    passwordCheck?.cancel()
    let backup = backup
    passwordCheck = Task {
      do {
        try await backup.checkPassword(typed)
        guard !isClosed else { return }
        password = typed
        state.passwordAsk = nil
        let asked = afterPassword
        afterPassword = []
        retryFailed()
        for retry in asked { retry() }
      } catch is CancellationError {
      } catch BackupBuff.Failure.passwordDoesNotOpen {
        state.passwordAsk = PasswordAsk(macName: "This Mac", isWrong: true, isForThisMac: true)
      } catch {
        // Not the password's fault (offline, signed out): said as the page says it.
        state.passwordAsk = nil
        afterPassword = []
        let problem = await describe(error, while: .listing)
        if !isClosed { await appModel.tell(problem, from: error) }
      }
    }
  }

  func cancelPassword() {
    passwordCheck?.cancel()
    state.passwordAsk = nil
    afterPassword = []
  }

  // MARK: Restoring

  /// Restore: the item, from the backup shown, back where it was or beside what is there now;
  /// when the folder isn't on this Mac, into a folder the user chooses.
  func restore(_ item: BackupItem) {
    guard let kept = state.backup else { return }
    let place = BackupPlace(backupID: kept.id, path: item.path)
    guard restores[place] == nil else { return }
    var chosen: URL?
    if state.isFolderAway {
      chosen = NSOpenPanel.chooseFolderToRestoreInto(
        message: "\(state.folderName) isn't on this Mac now. Choose where to put \(item.name)")
      guard chosen != nil else { return }
    }
    let path = URL(fileURLWithPath: state.folderPath).appendingPathComponent(item.path).path
    state.restores[place] = .restoring(RestoreRun(folderName: item.name, path: path))
    let (backup, folderID, password) = (backup, folderID, password)
    let run = UUID()
    let task = Task {
      let report: @Sendable (RestoreProgress) -> Void = { progress in
        Task { @MainActor in self.restoreDidProgress(progress, place: place, item: item, run: run) }
      }
      do {
        let restored = try await backup.restore(
          item, from: kept, folderID: folderID, into: chosen, password: password,
          onProgress: report)
        guard isCurrent(run, at: place) else { return }
        state.restores[place] = .done(path: restored.path)
        relistParent(of: item)
      } catch {
        guard isCurrent(run, at: place) else { return }
        if error is CancellationError {
          state.restores[place] = nil
        } else {
          let problem = await describe(
            error, while: .item(name: item.name), retry: { [weak self] in self?.restore(item) })
          guard isCurrent(run, at: place) else { return }
          state.restores[place] = .failed(problem)
          if isClosed { await appModel.tell(problem, from: error) }
        }
      }
      restores[place] = nil
    }
    restores[place] = (run, task)
  }

  /// Cancel: the row lets go at once, while restic stops (a moment, 30 seconds at most).
  func cancelRestore(_ place: BackupPlace) {
    restores[place]?.task.cancel()
    restores[place] = nil
    state.restores[place] = nil
  }

  private func isCurrent(_ run: UUID, at place: BackupPlace) -> Bool {
    restores[place]?.run == run
  }

  private func restoreDidProgress(
    _ progress: RestoreProgress, place: BackupPlace, item: BackupItem, run: UUID
  ) {
    guard isCurrent(run, at: place), case .restoring(let shown) = state.restores[place] else {
      return
    }
    state.restores[place] = .restoring(
      RestoreRun(folderName: item.name, path: shown.path, progress: progress))
  }

  /// What came back changes the marks of the folder it went into, in every backup listed.
  private func relistParent(of item: BackupItem) {
    for place in state.listings.keys where place.path == item.parent && listings[place] == nil {
      list(place)
    }
  }

  /// Restore Folder…, for the backup shown.
  func restoreFolder() {
    guard let kept = state.backup else { return }
    var directory: URL?
    if state.isFolderAway {
      directory = NSOpenPanel.chooseFolderToRestoreInto(
        message: "\(state.folderName) isn't on this Mac now. Choose where to put it back")
      guard directory != nil else { return }
    }
    appModel.restoreFolder(
      folderID: folderID, backup: kept, password: password, into: directory,
      askForPassword: { [weak self] in self?.askForPassword(then: { self?.restoreFolder() }) })
  }

  /// Asks for the password on the page; once it opens the backup, `retry` runs.
  private func askForPassword(then retry: @escaping @MainActor () -> Void) {
    guard !isClosed else { return }
    afterPassword.append(retry)
    state.passwordAsk = PasswordAsk(macName: "This Mac", isForThisMac: true)
  }

  // MARK: Quick Look and Finder

  /// Downloads the file into the page's own folder and shows it in Quick Look. The previous
  /// preview's copy goes as this one starts, so copies don't pile up while the page is open.
  func showQuickLook(_ item: BackupItem) {
    guard !isClosed, let kept = state.backup, state.canQuickLook(item), quickLook == nil else {
      return
    }
    state.quickLooking = BackupPlace(backupID: kept.id, path: item.path)
    quickLookURL = nil
    if let previewFolder { try? FileManager.default.removeItem(at: previewFolder) }
    let folder = quickLookFolder.appendingPathComponent(UUID().uuidString)
    previewFolder = folder
    let (backup, folderID, password) = (backup, folderID, password)
    quickLook = Task {
      defer {
        state.quickLooking = nil
        quickLook = nil
      }
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let downloaded = try await backup.download(
          item, from: kept, folderID: folderID,
          to: folder.appendingPathComponent(item.name), password: password)
        guard !isClosed, !Task.isCancelled else { return }
        quickLookURL = downloaded
      } catch {
        // Closed or stopped: its folder went with it, and there's nobody to tell.
        guard !isClosed, !Task.isCancelled, !(error is CancellationError) else { return }
        let problem = await describe(
          error, while: .preview(name: item.name),
          retry: { [weak self] in self?.showQuickLook(item) })
        if state.passwordAsk == nil { await appModel.tell(problem, from: error) }
      }
    }
  }

  /// A drag of `item` starting: what writes it where Finder drops it. It holds the backup, the
  /// folder and the password as they are now, so it works however long Finder takes to ask and
  /// whatever became of the page meanwhile; and tells of a failure in an alert.
  func prepareDragOut(_ item: BackupItem, backupID: String) -> BackupFilePromise.Write? {
    guard !isClosed, let kept = state.keptBackups.first(where: { $0.id == backupID }) else {
      return nil
    }
    let (backup, folderID, password, appModel) = (backup, folderID, password, appModel)
    return { [weak self] url in
      await self?.dragDidStart()
      do {
        // Exactly where Finder said: it has already shown the item under that name.
        _ = try await backup.download(
          item, from: kept, folderID: folderID, to: url, password: password)
        await self?.dragDidEnd()
      } catch {
        await self?.dragDidEnd()
        // Finder is told first, through the promise's completion; the alert follows on its own.
        Task {
          await appModel.tell(RestoreProblem(error, while: .item(name: item.name)), from: error)
        }
        throw error
      }
    }
  }

  private func dragDidStart() { state.dragsInFlight += 1 }
  private func dragDidEnd() { state.dragsInFlight -= 1 }

  /// The page went: listings and Quick Look stop and its downloads go. A restore carries on and
  /// says so with an alert if it fails.
  func close() {
    isClosed = true
    for task in listings.values { task.cancel() }
    quickLook?.cancel()
    passwordCheck?.cancel()
    password = nil
    afterPassword = []
    quickLookURL = nil
    try? FileManager.default.removeItem(at: quickLookFolder)
  }
}
