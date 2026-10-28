import DirBuffCore
import DirBuffKit
import Foundation

/// Which folders the sidebar shows on the shelf.
public enum ShelfFilter: Hashable, Sendable {
  case allFolders
  case needsYou
  case buff(Buff)
  /// "/" for the startup disk, or "/Volumes/<Name>" for another volume.
  case location(String)
}

/// A volume with at least one folder on the shelf, listed under Locations in the sidebar.
public struct ShelfLocation: Sendable, Equatable, Hashable, Identifiable {
  public var id: String { volumePath }
  public var volumePath: String
  public var name: String
  public var isExternal: Bool
  public var count: Int

  public init(volumePath: String, name: String, isExternal: Bool, count: Int) {
    self.volumePath = volumePath
    self.name = name
    self.isExternal = isExternal
    self.count = count
  }
}

/// One item in a folder's "Add a Buff to …" menu: only buffs the folder doesn't wear yet.
public struct AddBuffItem: Sendable, Equatable, Identifiable {
  public var id: Buff { buff }
  public var buff: Buff
  public var isEnabled: Bool
  public var subtitle: String?

  public init(buff: Buff, isEnabled: Bool, subtitle: String? = nil) {
    self.buff = buff
    self.isEnabled = isEnabled
    self.subtitle = subtitle
  }
}

extension FolderState {
  /// Whether any buff on the folder needs the user to fix something. A licence pause marks the
  /// folder needs you too, but its fix is the licence's, so the tile stays as it is.
  public var isNeedingYou: Bool {
    buffs.contains {
      if case .needsYou = $0.state { return true }
      return false
    }
  }

  /// Whether the folder wears `buff` (paused buffs still count; one just taken off doesn't).
  public func wears(_ buff: Buff) -> Bool {
    buffs.contains { $0.buff == buff }
  }
}

/// A folder shown in the pushed folder page (`FolderDetailView`).
public struct MainFolder: Sendable, Equatable, Identifiable {
  public var id: Int64
  public var name: String
  public var path: String
  public var isTemporary: Bool
  public var isReadable: Bool
  public var settings: TemporarySettings
  public var preview: FolderPreview

  public init(
    id: Int64,
    name: String,
    path: String,
    isTemporary: Bool,
    isReadable: Bool,
    settings: TemporarySettings,
    preview: FolderPreview
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.isTemporary = isTemporary
    self.isReadable = isReadable
    self.settings = settings
    self.preview = preview
  }
}

/// What the main window shows: the shelf of folder tiles, its sidebar counts and filters, and the
/// folder pages pushed over it.
public struct MainState: Sendable, Equatable {
  public var folders: [MainFolder]
  /// Every buffed folder (and any whose buff can still be put back), needs-you first then by name.
  public var shelfFolders: [FolderState]
  public var licenceLine: LicenceLine?
  /// Why no folder can be made Temporary right now; nil while it can.
  public var licenceRefusal: String?
  /// What the button beside that reason is called.
  public var buyTitle: String
  public var mayClean: Bool
  public var startupVolumeName: String
  public var protectedPaths: Set<String>

  /// Needs You leaves the sidebar while every buff is paused.
  public var showsNeedsYouInSidebar: Bool { mayClean }

  public var needsYouCount: Int { shelfFolders.count(where: \.isNeedingYou) }

  /// Shipped buffs listed in the sidebar; Soon buffs stay out until a folder can wear them.
  public var sidebarBuffs: [Buff] { Buff.allCases.filter(\.isAvailable) }

  public func buffCount(_ buff: Buff) -> Int {
    shelfFolders.count { $0.wears(buff) }
  }

  /// One row per volume that holds at least one shelf folder: startup disk first, then by name.
  public var locations: [ShelfLocation] {
    var startupCount = 0
    var externalCounts: [String: Int] = [:]
    for folder in shelfFolders {
      if let external = externalVolumeName(of: folder.path) {
        externalCounts[external, default: 0] += 1
      } else {
        startupCount += 1
      }
    }
    var result: [ShelfLocation] = []
    if startupCount > 0 {
      result.append(
        ShelfLocation(
          volumePath: "/", name: startupVolumeName, isExternal: false, count: startupCount))
    }
    let externals = externalCounts.keys.sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
    for name in externals {
      guard let count = externalCounts[name] else { continue }
      result.append(
        ShelfLocation(
          volumePath: "/Volumes/\(name)", name: name, isExternal: true, count: count))
    }
    return result
  }

  /// Falls back to All Folders when the chosen sidebar row is gone (an unplugged volume, or Needs
  /// You after the trial ends).
  public func resolvedFilter(_ filter: ShelfFilter) -> ShelfFilter {
    switch filter {
    case .allFolders:
      return .allFolders
    case .needsYou:
      return showsNeedsYouInSidebar ? .needsYou : .allFolders
    case .buff(let buff):
      return sidebarBuffs.contains(buff) ? .buff(buff) : .allFolders
    case .location(let volumePath):
      return locations.contains(where: { $0.volumePath == volumePath })
        ? .location(volumePath) : .allFolders
    }
  }

  /// The tiles to draw for `filter` and the name filter `query`, keeping shelf order.
  public func shelfFolders(
    matching filter: ShelfFilter = .allFolders,
    query: String = ""
  ) -> [FolderState] {
    let byFilter: [FolderState] =
      switch resolvedFilter(filter) {
      case .allFolders:
        shelfFolders
      case .needsYou:
        shelfFolders.filter(\.isNeedingYou)
      case .buff(let buff):
        shelfFolders.filter { $0.wears(buff) }
      case .location(let volumePath):
        shelfFolders.filter { volumeIdentifier(of: $0.path) == volumePath }
      }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return byFilter }
    return byFilter.filter { $0.name.localizedStandardContains(trimmed) }
  }

  public func toolbarTitle(for filter: ShelfFilter) -> String {
    switch resolvedFilter(filter) {
    case .allFolders:
      "Folders"
    case .needsYou:
      "Needs You"
    case .buff(let buff):
      buff.name
    case .location(let volumePath):
      locations.first(where: { $0.volumePath == volumePath })?.name ?? "Folders"
    }
  }

  /// "6 folders · 1 needs you", "6 folders · all paused", or "6 folders".
  public func toolbarSubtitle(for filter: ShelfFilter) -> String {
    let inScope = shelfFolders(matching: filter)
    guard !inScope.isEmpty else { return "No folders" }
    let total = folderCountWords(inScope.count)
    if !mayClean {
      return inScope.count == 1 ? "\(total) · paused" : "\(total) · all paused"
    }
    let needing = inScope.count(where: \.isNeedingYou)
    if needing == 0 { return total }
    if needing == 1 { return "\(total) · 1 needs you" }
    return "\(total) · \(needing) need you"
  }

  public func isProtected(path: String) -> Bool {
    protectedPaths.contains(path) || isExternalVolumeRoot(path)
  }

  /// The buffs `folder` doesn't wear yet, for its "Add a Buff to …" menu.
  public func addBuffItems(for folder: FolderState) -> [AddBuffItem] {
    Buff.allCases.compactMap { buff in
      guard !folder.wears(buff) else { return nil }
      guard buff.isAvailable else {
        return AddBuffItem(buff: buff, isEnabled: false, subtitle: "Soon")
      }
      if !mayClean {
        return AddBuffItem(buff: buff, isEnabled: false)
      }
      if isProtected(path: folder.path) {
        return AddBuffItem(
          buff: buff,
          isEnabled: false,
          subtitle: "\(folder.name) is protected. DirBuff never clears it.")
      }
      return AddBuffItem(buff: buff, isEnabled: true)
    }
  }
}

extension MainState {
  public init(
    reports: [FolderReport],
    licence: Licence,
    working: Set<Int64> = [],
    progress: Engine.RunProgress? = nil,
    now: Date,
    calendar: Calendar = .current,
    binName: String = SystemBin.name,
    home: String = NSHomeDirectory(),
    startupVolumeName: String? = nil,
    protectedPaths: Set<String>? = nil
  ) {
    self.licenceLine = licence.line
    self.licenceRefusal = licence.refusal
    self.buyTitle = licence.buyTitle
    self.mayClean = licence.mayClean
    self.startupVolumeName = startupVolumeName ?? Self.defaultStartupVolumeName
    self.protectedPaths =
      protectedPaths
      ?? Set(protectedRoots(home: URL(fileURLWithPath: home), volumes: []).map(\.path))
    self.shelfFolders = sortForShelf(
      FolderState.all(
        reports,
        licence: licence,
        working: working,
        progress: progress,
        now: now,
        calendar: calendar,
        binName: binName,
        home: home
      ))
    self.folders = reports.compactMap { report in
      guard let id = report.folder.id else { return nil }
      let isReadable = report.status != nil
      let isTemporary = report.status?.wearsTemporary == true
      let preview: FolderPreview = {
        guard let status = report.status else {
          return FolderPreview(headline: "Can't read this folder", forecast: [])
        }
        if !licence.mayClean {
          return FolderPreview(headline: "Cleaning is paused", forecast: [])
        }
        return FolderPreview(
          status,
          settings: report.folder.settings,
          now: now,
          calendar: calendar,
          binName: binName
        )
      }()
      return MainFolder(
        id: id,
        name: report.name,
        path: report.folder.path,
        isTemporary: isTemporary,
        isReadable: isReadable,
        settings: report.folder.settings,
        preview: preview
      )
    }
  }

  private static var defaultStartupVolumeName: String {
    let display = FileManager.default.displayName(atPath: "/")
    return display.isEmpty || display == "/" ? "Macintosh HD" : display
  }
}

/// Needs-you folders first, then alphabetical by folder name.
private func sortForShelf(_ folders: [FolderState]) -> [FolderState] {
  folders.sorted { lhs, rhs in
    if lhs.isNeedingYou != rhs.isNeedingYou {
      return lhs.isNeedingYou
    }
    let byName = lhs.name.localizedStandardCompare(rhs.name)
    if byName != .orderedSame {
      return byName == .orderedAscending
    }
    return lhs.id < rhs.id
  }
}

private func folderCountWords(_ count: Int) -> String {
  count == 1 ? "1 folder" : "\(count) folders"
}

private func externalVolumeName(of path: String) -> String? {
  let parts = path.split(separator: "/")
  guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
  return String(parts[1])
}

private func isExternalVolumeRoot(_ path: String) -> Bool {
  let parts = path.split(separator: "/")
  return parts.count == 2 && parts[0] == "Volumes"
}

private func volumeIdentifier(of path: String) -> String {
  externalVolumeName(of: path).map { "/Volumes/\($0)" } ?? "/"
}
