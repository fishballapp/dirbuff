import Cocoa
import Darwin
import FinderSync
import os.log

private let extLogger = Logger(subsystem: "app.fishball.dirbuff", category: "findersync")

@objc(FinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {
  /// Held for as long as its observations: an observation doesn't keep its object alive.
  private let shared = FinderFolders.defaults
  private var listObservation: NSKeyValueObservation?
  private var volumeTopObservation: NSKeyValueObservation?

  override init() {
    super.init()
    extLogger.info("DirBuff FinderSyncExtension initializing")

    Self.watch(volumeTopFolderPaths: shared?.volumeTopFolderPaths ?? [])
    FIFinderSyncController.default().setBadgeImage(
      NSImage(resource: .temporaryBadge), label: "DirBuff: Temporary",
      forBadgeIdentifier: Self.temporaryBadge)
    listObservation = shared?.observe(
      \.temporaryFolderPaths, options: [.old, .new]
    ) { _, change in
      Self.rebadge(from: Set(change.oldValue ?? []), to: Set(change.newValue ?? []))
    }
    volumeTopObservation = shared?.observe(\.volumeTopFolderPaths, options: [.new]) { _, change in
      Self.watch(volumeTopFolderPaths: change.newValue ?? [])
    }
  }

  /// `/` covers the startup disk only. Another volume is covered through the folders at its top,
  /// which the app lists: watching the volume itself would put DirBuff's icon on it in Finder's
  /// sidebar.
  private static func watch(volumeTopFolderPaths: [String]) {
    let directories = Set((["/"] + volumeTopFolderPaths).map { URL(fileURLWithPath: $0) })
    FIFinderSyncController.default().directoryURLs = directories
    extLogger.info("Watching \(directories.count, privacy: .public) folders")
  }

  // MARK: - Badge

  private static let temporaryBadge = "temporary"

  override func requestBadgeIdentifier(for url: URL) {
    FIFinderSyncController.default().setBadgeIdentifier(
      isTemporary(url) ? Self.temporaryBadge : "", for: url)
  }

  private func isTemporary(_ folder: URL) -> Bool {
    (shared?.temporaryFolderPaths ?? []).contains(folder.resolvingSymlinksInPath().path)
  }

  private func isAdded(_ folder: URL) -> Bool {
    (shared?.addedFolderPaths ?? []).contains(folder.resolvingSymlinksInPath().path)
  }

  private func isProtected(_ folder: URL) -> Bool {
    (shared?.protectedFolderPaths ?? []).contains(folder.resolvingSymlinksInPath().path)
  }

  /// Finder asks for a badge only when an item comes into view, so a folder made Temporary or
  /// plain while in view is rebadged here.
  private static func rebadge(from old: Set<String>, to new: Set<String>) {
    let controller = FIFinderSyncController.default()
    for path in old.subtracting(new) {
      controller.setBadgeIdentifier("", for: URL(fileURLWithPath: path))
    }
    for path in new.subtracting(old) {
      controller.setBadgeIdentifier(temporaryBadge, for: URL(fileURLWithPath: path))
    }
  }

  // MARK: - Menu

  override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer,
      let folder = Self.targetFolder(),
      !isProtected(folder)
    else {
      return nil
    }

    let menu = NSMenu(title: "")
    let item = NSMenuItem(
      title: isAdded(folder) ? "Show in DirBuff" : "Add to DirBuff…",
      action: #selector(openFolderAction(_:)),
      keyEquivalent: ""
    )
    item.target = self
    menu.addItem(item)
    return menu
  }

  /// The folder a right-click is about: the one folder selected, or with nothing selected, the
  /// folder clicked in. A file, an app or several items get no item: it would act on the folder
  /// around them.
  private static func targetFolder() -> URL? {
    let controller = FIFinderSyncController.default()
    let selected = controller.selectedItemURLs() ?? []
    switch selected.count {
    case 0: return controller.targetedURL()
    case 1: return isFolder(selected[0]) ? selected[0] : nil
    default: return nil
    }
  }

  private static func isFolder(_ url: URL) -> Bool {
    do {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
      return values.isDirectory == true && values.isPackage != true
    } catch {
      extLogger.error(
        "Couldn't read the selected item: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  @objc private func openFolderAction(_ sender: AnyObject?) {
    guard let folder = Self.targetFolder() else {
      extLogger.warning("DirBuff menu item invoked with no target directory")
      return
    }

    var components = URLComponents()
    components.scheme = "dirbuff"
    components.host = "folder"
    components.queryItems = [
      URLQueryItem(name: "path", value: folder.path)
    ]

    guard let handoffURL = components.url else {
      extLogger.error("Failed to construct handoff URL for \(folder.path, privacy: .private)")
      return
    }

    let opened = NSWorkspace.shared.open(handoffURL)
    extLogger.info(
      "Handoff to DirBuff returned \(opened, privacy: .public) for \(folder.path, privacy: .private)"
    )
  }
}
