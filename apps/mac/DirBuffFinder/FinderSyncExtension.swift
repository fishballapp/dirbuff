import Cocoa
import Darwin
import DirBuffUI
import FinderSync
import os.log

private let extLogger = Logger(subsystem: "app.fishball.dirbuff", category: "findersync")

@objc(FinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {
  /// Held for as long as its observations: an observation doesn't keep its object alive.
  private let shared = FinderFolders.defaults
  private var snapshotObservation: NSKeyValueObservation?
  private var volumeTopObservation: NSKeyValueObservation?

  override init() {
    super.init()
    extLogger.info("DirBuff FinderSyncExtension initializing")

    Self.watch(volumeTopFolderPaths: shared?.volumeTopFolderPaths ?? [])
    MainActor.assumeIsolated {
      Self.registerBadges()
    }
    snapshotObservation = shared?.observe(
      \.finderSnapshot, options: [.old, .new]
    ) { _, change in
      let old = FinderSnapshot.decode(change.oldValue ?? nil)
      let next = FinderSnapshot.decode(change.newValue ?? nil)
      Self.rebadge(from: old, to: next)
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

  @MainActor
  private static func registerBadges() {
    let controller = FIFinderSyncController.default()
    for state in MarkState.allCases {
      controller.setBadgeImage(
        Mark.badgeImage(for: state),
        label: state.badgeLabel,
        forBadgeIdentifier: state.badgeIdentifier
      )
    }
  }

  override func requestBadgeIdentifier(for url: URL) {
    let mark = shared?.snapshot.badge(for: url)
    FIFinderSyncController.default().setBadgeIdentifier(
      mark?.badgeIdentifier ?? "", for: url
    )
  }

  /// Finder asks for a badge only when an item comes into view, so a folder whose mark changes
  /// while in view is rebadged here.
  private static func rebadge(from old: FinderSnapshot, to next: FinderSnapshot) {
    let controller = FIFinderSyncController.default()
    for change in next.badgeChanges(from: old) {
      controller.setBadgeIdentifier(
        change.mark?.badgeIdentifier ?? "",
        for: URL(fileURLWithPath: change.path)
      )
    }
  }

  // MARK: - Menu

  override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer,
      let folder = Self.targetFolder()
    else {
      return nil
    }

    let spec = (shared?.snapshot ?? FinderSnapshot()).menu(for: folder)
    return buildMenu(spec)
  }

  private func buildMenu(_ spec: FinderMenu) -> NSMenu {
    let submenu = NSMenu(title: spec.title)
    submenu.autoenablesItems = false
    for entry in spec.items {
      switch entry.kind {
      case .separator:
        submenu.addItem(.separator())
      case .sectionHeader:
        let header = NSMenuItem.sectionHeader(title: entry.title)
        header.isEnabled = false
        submenu.addItem(header)
      case .item:
        let item = NSMenuItem(
          title: entry.title,
          action: entry.action.map(Self.selector(for:)),
          keyEquivalent: ""
        )
        if #available(macOS 14.4, *) {
          item.subtitle = entry.subtitle
        } else if let subtitle = entry.subtitle {
          item.title = "\(entry.title) \u{2014} \(subtitle)"
        }
        item.isEnabled = entry.isEnabled
        if entry.action != nil {
          item.target = self
        }
        if let buff = entry.buff {
          item.image = MainActor.assumeIsolated {
            BuffSymbol.menuImage(for: buff)
          }
        }
        submenu.addItem(item)
      }
    }

    let root = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
    root.submenu = submenu
    let menu = NSMenu(title: "")
    menu.autoenablesItems = false
    menu.addItem(root)
    return menu
  }

  private static func selector(for action: FinderAction) -> Selector {
    switch action {
    case .addTemporary: #selector(addTemporaryAction(_:))
    case .takeTemporaryOff: #selector(takeTemporaryOffAction(_:))
    case .change: #selector(changeAction(_:))
    case .whatsClearedNext: #selector(whatsClearedNextAction(_:))
    case .openFolder: #selector(openFolderAction(_:))
    }
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

  @objc private func addTemporaryAction(_ sender: AnyObject?) {
    perform(.addTemporary)
  }

  @objc private func takeTemporaryOffAction(_ sender: AnyObject?) {
    perform(.takeTemporaryOff)
  }

  @objc private func changeAction(_ sender: AnyObject?) {
    perform(.change)
  }

  @objc private func whatsClearedNextAction(_ sender: AnyObject?) {
    perform(.whatsClearedNext)
  }

  @objc private func openFolderAction(_ sender: AnyObject?) {
    perform(.openFolder)
  }

  private func perform(_ action: FinderAction) {
    guard let folder = Self.targetFolder() else {
      extLogger.warning("DirBuff menu item invoked with no target directory")
      return
    }
    guard let handoffURL = action.url(for: folder) else {
      extLogger.error("Failed to construct handoff URL for \(folder.path, privacy: .private)")
      return
    }
    let opened = NSWorkspace.shared.open(handoffURL)
    extLogger.info(
      "Handoff to DirBuff (\(action.rawValue, privacy: .public)) returned \(opened, privacy: .public) for \(folder.path, privacy: .private)"
    )
  }
}
