import AppKit
import DirBuffCore
import DirBuffKit
import DirBuffUI
import FinderSync
import ServiceManagement
import UserNotifications
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "app")

/// The app's state and every action the windows take. Engine calls touch the disk, so they run
/// off the main actor.
@Observable
@MainActor
final class AppModel {
  static let showInMenuBarKey = "showInMenuBar"
  static let protectedFolderExplanation =
    "DirBuff doesn't clear your home folder, Library, system folders or the top of a disk. Choose a folder inside one, such as Downloads."

  private(set) var reports: [FolderReport] = []
  private(set) var isFinderExtensionOff = false
  private(set) var isLoginItemEnabled = false
  private(set) var loginItemNeedsApproval = false
  private(set) var isNotificationAuthorized = false
  private(set) var licenceRecord: LicenceRecord
  /// The folders a clean-up is running in now.
  private(set) var working: Set<Int64> = [] {
    didSet { publishForFinder() }
  }
  /// How far the folder a clean-up is running in now has got; nil between runs.
  private(set) var runProgress: RunProgress?
  /// Goes up whenever History changes (a clean-up, a Put Back, trimming or clearing), so open
  /// History pages read it again. Set only by `historyDidChange()` in `AppModel+History`, which
  /// is why it can't be `private(set)` here.
  var historyRevision = 0
  /// The run a clean-up is writing to now, which Clear History keeps; nil between clean-ups.
  private(set) var openRunID: Int64?

  let engine: Engine
  let temporary: TemporaryBuff
  private let polar: PolarLicensing
  private let polarSettings: PolarSettings
  private let machine: String
  private let releaseDay: ReleaseDay
  private var scheduler: BuffScheduler?

  init() {
    do {
      let directory = URL.applicationSupportDirectory.appendingPathComponent("DirBuff")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      engine = Engine(
        store: try Store(path: directory.appendingPathComponent("dirbuff.sqlite").path))
      temporary = TemporaryBuff(engine: engine)
      licenceRecord = try engine.store.licence()
      polarSettings = try PolarSettings.fromInfoPlist()
      machine = try Machine.id()
      releaseDay = try BuildInfo.releaseDay()
    } catch {
      Self.quit(because: error)
    }
    polar = PolarLicensing(api: polarSettings.api, organizationID: polarSettings.organizationID)
    refreshSystemStatus()
    startScheduler()
  }

  private static func quit(because error: any Error) -> Never {
    logger.fault("Couldn't start: \(error.localizedDescription, privacy: .public)")
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "DirBuff can't start"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "Quit")
    alert.runModal()
    exit(1)
  }

  /// Read afresh each time: the trial's days pass without the record changing.
  var licence: Licence { licence(now: Date()) }

  func licence(now: Date) -> Licence {
    Licence(licenceRecord, now: now, release: releaseDay)
  }

  /// Every folder as the shelf, sidebar, popover and Finder show it.
  func folders(now: Date) -> [FolderState] {
    FolderState.all(
      reports, licence: licence(now: now), working: working, progress: runProgress, now: now)
  }

  /// The folder at `url`, matched by canonical path: the store keeps `/private/var/…`
  /// where Finder may hand over `/var/…`.
  func report(for url: URL) -> FolderReport? {
    let path = try? canonicalPath(of: url)
    return reports.first { $0.folder.path == path }
  }

  // MARK: - System status

  func refreshSystemStatus() {
    isFinderExtensionOff = !FIFinderSyncController.isExtensionEnabled
    isLoginItemEnabled = SMAppService.mainApp.status == .enabled
    loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    Task {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      isNotificationAuthorized = settings.authorizationStatus == .authorized
    }
  }

  func setOpenAtLogin(_ isOn: Bool) {
    do {
      if isOn {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      show(error, doing: isOn ? "turn on Open at login" : "turn off Open at login")
    }
    refreshSystemStatus()
  }

  func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  func openFinderExtensionsSettings() {
    FIFinderSyncController.showExtensionManagementInterface()
  }

  func requestNotificationPermission() {
    Task {
      do {
        isNotificationAuthorized = try await UNUserNotificationCenter.current()
          .requestAuthorization(options: [.alert])
      } catch {
        logger.error("Notification permission: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// The welcome window's Turn On. macOS asks only once, so after a refusal this opens the place
  /// to change it.
  func turnOnNotifications() {
    Task {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      guard settings.authorizationStatus == .denied else {
        requestNotificationPermission()
        return
      }
      if let url = URL(
        string:
          "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")"
      ) {
        NSWorkspace.shared.open(url)
      }
    }
  }

  // MARK: - Folders

  func refresh() async {
    let engine = engine
    let temporary = temporary
    do {
      let reports = try await Task.detached {
        var found: [Int64: (location: Result<URL, FolderProblem>, buffs: [BuffReading])] = [:]
        for id in try engine.store.folders().compactMap(\.id) {
          found[id] = try await Self.read(id, engine: engine, temporary: temporary)
        }
        // Finding a folder can change its record (a renamed folder's path), and so does recording
        // its access, so the records are fetched after.
        return try engine.store.folders().compactMap { folder in
          folder.id.flatMap { found[$0] }.map {
            FolderReport(folder: folder, location: $0.location, buffs: $0.buffs)
          }
        }
      }.value
      self.reports = reports
      publishForFinder()
    } catch {
      logger.error("Couldn't read the folders: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Finds the folder and reads each buff it wears. One unreadable folder (an unplugged drive)
  /// mustn't hide the others. Records whether macOS let DirBuff in, so a folder that needs the
  /// user can say since when.
  nonisolated private static func read(_ id: Int64, engine: Engine, temporary: TemporaryBuff)
    async throws -> (location: Result<URL, FolderProblem>, buffs: [BuffReading])
  {
    let located: Result<LocatedFolder, FolderProblem>
    do {
      located = .success(try engine.locate(folderID: id))
    } catch {
      logger.error("Couldn't find folder \(id): \(error.localizedDescription, privacy: .public)")
      located = .failure(FolderProblem(error))
    }
    // Read after finding it: taking a folder's old tag off can put Temporary on.
    let buffs = [
      try await read(temporary, located, folderID: id).map { BuffReading.temporary($0, $1) }
    ].compactMap(\.self)
    let location = located.map(\.url)
    let problem = FolderProblem(location: location, buffs: buffs)
    let isLost: Bool? =
      switch problem {
      case nil: false
      case .noAccess: true
      case .unreachable, .missing: nil
      }
    let isMissing: Bool? =
      switch problem {
      case nil, .noAccess: false
      case .missing: true
      case .unreachable: nil
      }
    do {
      if let isLost { try engine.store.recordAccess(folderID: id, isLost: isLost, at: Date()) }
      if let isMissing {
        try engine.store.recordMissing(folderID: id, isMissing: isMissing, at: Date())
      }
    } catch {
      logger.error("Couldn't record access: \(error.localizedDescription, privacy: .public)")
    }
    return (location, buffs)
  }

  /// The folder's wear of `module` and what reading it found: nil when it doesn't wear it, no
  /// reading when the folder wasn't found.
  nonisolated private static func read<Module: BuffModule>(
    _ module: Module, _ located: Result<LocatedFolder, FolderProblem>, folderID: Int64
  ) async throws -> (Wear<Module.Settings>, Result<Module.Reading, FolderProblem>?)? {
    guard let wear = try module.wear(folderID: folderID) else { return nil }
    guard case .success(let folder) = located else { return (wear, nil) }
    do {
      return (wear, .success(try await module.read(folder, wear, now: Date())))
    } catch {
      logger.error(
        "Couldn't read folder \(folderID): \(error.localizedDescription, privacy: .public)")
      return (wear, .failure(FolderProblem(error)))
    }
  }

  @discardableResult
  func addFolder(_ url: URL) async -> Folder? {
    let engine = engine
    do {
      let folder = try await Task.detached { try engine.add(url) }.value
      await refresh()
      return folder
    } catch {
      show(error, doing: "add \(url.lastPathComponent)")
      return nil
    }
  }

  /// Puts Temporary on the folder or takes it off; returns whether that happened.
  @discardableResult
  func setTemporary(_ folder: Folder, _ isOn: Bool) async -> Bool {
    guard let folderID = folder.id else { return false }
    let temporary = temporary
    let isDone: Bool
    do {
      try await Task.detached {
        if isOn {
          try temporary.putOn(folderID: folderID)
        } else {
          try temporary.takeOff(folderID: folderID)
        }
      }.value
      isDone = true
    } catch {
      show(
        error,
        doing: isOn
          ? "make \(URL(fileURLWithPath: folder.path).lastPathComponent) Temporary"
          : "make the folder plain again")
      isDone = false
    }
    await refresh()
    // Ask when the benefit is clear: right after the first folder is made Temporary.
    if isOn, isDone,
      reports.count(where: { $0.temporaryWear.map { !$0.isPausedByLicence } == true }) == 1
    {
      requestNotificationPermission()
    }
    return isDone
  }

  func remove(_ folder: Folder) async {
    let engine = engine
    do {
      try await Task.detached { try engine.remove(folder) }.value
    } catch {
      show(error, doing: "remove \(URL(fileURLWithPath: folder.path).lastPathComponent)")
    }
    await refresh()
  }

  func save(_ settings: TemporarySettings, for folder: Folder) async {
    guard let folderID = folder.id else { return }
    let temporary = temporary
    do {
      try await Task.detached { try temporary.save(settings, folderID: folderID) }.value
    } catch {
      show(error, doing: "save the folder's settings")
    }
    await refresh()
  }

  func putBack(entryIDs: [Int64]) async {
    guard !entryIDs.isEmpty else { return }
    let temporary = temporary
    var problems: [String] = []
    for id in entryIDs {
      do {
        try await Task.detached { try temporary.undo(journalEntryID: id) }.value
      } catch {
        problems.append(Self.explain(error))
      }
    }
    if !problems.isEmpty {
      alert(
        "Some items couldn't be put back", Array(Set(problems)).sorted().joined(separator: "\n"))
    }
    await refresh()
  }

  static func explain(_ error: any Error) -> String {
    switch error {
    case let failure as Engine.Failure: explain(failure)
    case let failure as TemporaryBuff.Failure: explain(failure)
    case let refusal as Refusal: explain(refusal)
    default: error.localizedDescription
    }
  }

  private static func explain(_ refusal: Refusal) -> String {
    switch refusal {
    case .protectedFolder: Self.protectedFolderExplanation
    }
  }

  private static func explain(_ failure: Engine.Failure) -> String {
    switch failure {
    case .protectedFolder: Self.protectedFolderExplanation
    case .folderNotFound: "DirBuff no longer knows about that folder."
    case .folderAlreadyAdded: "That folder is already in DirBuff."
    case .folderInBin:
      "That folder is in the \(SystemBin.name). Take it out to turn its buffs back on."
    case .folderMissing: "DirBuff can't find that folder. It may have been deleted or moved."
    }
  }

  private static func explain(_ failure: TemporaryBuff.Failure) -> String {
    switch failure {
    case .originalPathTaken(let path):
      let url = URL(fileURLWithPath: path)
      return
        "Something new is already called \(url.lastPathComponent) in \(url.deletingLastPathComponent().lastPathComponent), so it was left in the \(SystemBin.name)."
    case .goneFromBin: return "An item is no longer in the \(SystemBin.name)."
    case .deletedPermanently: return "Items deleted permanently can't be put back."
    case .alreadyUndone: return "Those items were already put back."
    case .changedSincePlanned(let path):
      return "\(URL(fileURLWithPath: path).lastPathComponent) changed, so it was left alone."
    case .journalEntryNotFound:
      return "DirBuff no longer knows about that folder."
    }
  }

  func show(_ error: any Error, doing action: String) {
    logger.error(
      "Couldn't \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
    alert("Couldn't \(action)", Self.explain(error))
  }

  func alert(_ title: String, _ message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.runModal()
  }

  // MARK: - Licence

  func openCheckout() {
    NSWorkspace.shared.open(polarSettings.checkout)
  }

  func openCustomerPortal() {
    NSWorkspace.shared.open(polarSettings.portal)
  }

  /// Activates the key on this Mac; returns why not, for the key window to show.
  func activate(key: String) async -> PolarLicensing.Failure? {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let activationID = try await polar.activate(key: key, label: Machine.name, machine: machine)
      licenceRecord = LicenceRecord(
        trialStartedAt: licenceRecord.trialStartedAt, key: key, activationID: activationID,
        lastCheckedAt: Date())
      saveLicence()
      return nil
    } catch {
      return error as? PolarLicensing.Failure ?? .unreachable
    }
  }

  /// After a key is activated, offers back the folders the trial's or licence's end made plain.
  func offerFoldersBack() async {
    let folders = reports.filter { $0.temporaryWear?.isPausedByLicence == true }.map(\.folder)
    if !folders.isEmpty {
      let names = folders.map { URL(fileURLWithPath: $0.path).lastPathComponent }
      let alert = NSAlert()
      alert.messageText =
        folders.count == 1
        ? "Make \(names[0]) Temporary again?"
        : "Make these \(folders.count) folders Temporary again?"
      alert.informativeText =
        folders.count == 1
        ? "It was made plain when DirBuff's licence ended." : names.joined(separator: ", ")
      alert.addButton(withTitle: "Make Temporary")
      alert.addButton(withTitle: "Not Now")
      if alert.runModal() == .alertFirstButtonReturn {
        for folder in folders { await setTemporary(folder, true) }
      } else {
        // Declining forgets their settings, as taking a buff off does.
        let temporary = temporary
        for folderID in folders.compactMap(\.id) {
          do {
            try await Task.detached { try temporary.takeOff(folderID: folderID) }.value
          } catch {
            logger.error(
              "Couldn't forget paused folders: \(error.localizedDescription, privacy: .public)")
          }
        }
      }
    }
    await refresh()
  }

  func deactivate() async {
    guard let key = licenceRecord.key, let activationID = licenceRecord.activationID else { return }
    let unlicensed = LicenceRecord(trialStartedAt: licenceRecord.trialStartedAt)
    let confirm = NSAlert()
    confirm.messageText = "Deactivate DirBuff on this Mac?"
    confirm.informativeText =
      if case .trial = Licence(unlicensed, now: Date(), release: releaseDay) {
        "DirBuff goes back to its trial until you enter a key again."
      } else {
        "Your folders become plain folders until you enter a key again."
      }
    confirm.addButton(withTitle: "Deactivate")
    confirm.addButton(withTitle: "Cancel")
    guard confirm.runModal() == .alertFirstButtonReturn else { return }
    do {
      try await polar.deactivate(key: key, activationID: activationID)
    } catch {
      alert("Couldn't deactivate this Mac", PolarLicensing.Failure.unreachable.message)
      return
    }
    licenceRecord = unlicensed
    saveLicence()
    await settleLicence(now: Date())
  }

  func checkLicenceNow() async {
    await checkLicence(now: Date())
    await settleLicence(now: Date())
  }

  /// No answer from Polar changes nothing: a build the last answer doesn't cover stays paused until
  /// an answer comes.
  private func checkLicence(now: Date) async {
    guard let key = licenceRecord.key, let activationID = licenceRecord.activationID else { return }
    do {
      let verdict = try await polar.validate(
        key: key, activationID: activationID, machine: machine)
      // The key may have been deactivated or replaced while Polar answered.
      guard licenceRecord.activationID == activationID else { return }
      switch verdict {
      case .granted: licenceRecord.lastCheckedAt = now
      case .ended: licenceRecord.hasEnded = true
      }
      saveLicence()
    } catch {
      logger.info("Couldn't check the licence: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func saveLicence() {
    do {
      try engine.store.save(licenceRecord)
    } catch {
      // Unsaved, the next launch forgets the key and falls back to the trial.
      show(error, doing: "save DirBuff's licence")
    }
  }

  /// Makes every Temporary folder plain once the trial or licence has ended. Folders already plain
  /// are skipped, so it does its work once per end.
  private func makeFoldersPlain(_ licence: Licence) async {
    let temporary = temporary
    let wearing = reports.compactMap(\.temporaryWear).filter { !$0.isPausedByLicence }
    guard !wearing.isEmpty else { return }
    for wear in wearing {
      do {
        try await Task.detached {
          try temporary.setPausedByLicence(true, folderID: wear.folderID)
        }.value
      } catch {
        logger.error(
          "Couldn't pause folder \(wear.folderID): \(error.localizedDescription, privacy: .public)")
      }
    }
    await refresh()
    switch licence {
    case .trialEnded:
      await notify(
        id: "licence.ended", title: "DirBuff's trial has ended",
        body: "Your folders are plain folders again. Support DirBuff to turn them back on.")
    default:
      await notify(
        id: "licence.ended", title: "Your DirBuff licence ended before this version",
        body: "Your folders are plain folders again. Renew DirBuff to use this version.")
    }
  }

  // MARK: - Running the buffs

  /// The model lives as long as the app, so the observers below hold it strongly.
  private func startScheduler() {
    Task { await settleLicence(now: Date()) }
    let scheduler = BuffScheduler { schedule, date in await self.runDue(schedule, at: date) }
    scheduler.start()
    self.scheduler = scheduler
    let workspace = NSWorkspace.shared.notificationCenter
    workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
      _ in Task { @MainActor in await self.settleLicence(now: Date()) }
    }
    workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) {
      _ in Task { @MainActor in await self.refresh() }
    }
    workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) {
      _ in Task { @MainActor in await self.refresh() }
    }
    // Opening the menu-bar window doesn't activate an accessory app, so the status is re-read
    // whenever one of its windows becomes key: back from System Settings, the warning must be gone.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { _ in Task { @MainActor in self.refreshSystemStatus() } }
  }

  /// Runs each buff whose schedule fell due.
  private func runDue(_ schedule: BuffSchedule, at date: Date) async {
    if temporary.schedule == schedule { await cleanUp(at: date) }
  }

  /// Checks the licence with Polar when a check is due, makes the folders plain once the licence
  /// has ended, and says the day before the trial ends.
  private func settleLicence(now: Date) async {
    if licenceRecord.isCheckDue(now: now, release: releaseDay) {
      await checkLicence(now: now)
    }
    await refresh()
    let licence = licence(now: now)
    if licence.plainsFolders {
      await makeFoldersPlain(licence)
    }
    if licence == .trial(daysLeft: 1) {
      await notifyOncePerDay(
        id: "trialEndsTomorrow", now: now, title: "DirBuff's trial ends tomorrow",
        body: "Then your folders become plain folders. Support DirBuff to keep them Temporary.")
    }
  }

  /// Runs every folder that wears Temporary, one after another: each run reads free space after
  /// the last one freed some. Each run counts from `hour`, not from when the timer fired, so it
  /// removes what the forecast said would be cleared at that hour. Polar is asked afterwards, not
  /// before: a build the last answer covers needs no answer to run, and one it doesn't is paused
  /// and never runs. So the run starts on the hour, before the user can change what was shown.
  private func cleanUp(at hour: Date) async {
    guard licence(now: hour).mayClean else {
      await settleLicence(now: hour)
      return
    }

    let engine = engine
    let temporary = temporary
    let runID: Int64?
    do {
      runID = try engine.store.beginRun(of: temporary.buff, at: hour)
    } catch {
      logger.error("Couldn't open a run: \(error.localizedDescription, privacy: .public)")
      runID = nil
    }
    openRunID = runID
    // One the licence paused runs too, removing nothing, so its run times stay current.
    let folderIDs: [Int64]
    do {
      folderIDs = try temporary.wearers().map(\.folderID)
    } catch {
      logger.error("Couldn't list the folders: \(error.localizedDescription, privacy: .public)")
      folderIDs = []
    }
    for id in folderIDs {
      // The licence can end or be deactivated while earlier folders run.
      guard self.licence.mayClean else { break }
      working.insert(id)
      defer {
        working.remove(id)
        runProgress = nil
      }
      let context = RunContext(runID: runID, scheduledAt: hour) { progress in
        // A report that lands after its folder finished is dropped.
        Task { @MainActor in
          if self.working.contains(progress.folderID) { self.runProgress = progress }
        }
      }
      do {
        try await Task.detached {
          // Read now, not before the first folder ran: the user may have changed it since.
          guard let wear = try temporary.wear(folderID: id) else { return }
          _ = try temporary.run(engine.locate(folderID: id), wear, context: context)
        }.value
      } catch {
        logger.error("Run of folder \(id) failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    openRunID = nil
    if let runID {
      do {
        try engine.store.dropRunIfEmpty(id: runID)
      } catch {
        logger.error("Couldn't close the run: \(error.localizedDescription, privacy: .public)")
      }
    }
    await settleLicence(now: hour)
    await didCleanUp(runID: runID, at: hour)
  }
}
