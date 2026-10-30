import DirBuffCore
import DirBuffKit
import Foundation

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
  /// Whether the user must fix something: a buff on the folder needs them, or a folder that wears
  /// nothing has gone missing. A licence pause marks the folder needs you too, but its fix is the
  /// licence's, so the tile stays as it is.
  public var isNeedingYou: Bool {
    let isBuffNeedingYou = buffs.contains {
      if case .needsYou = $0.state { return true }
      return false
    }
    return isBuffNeedingYou || (buffs.isEmpty && isMissing)
  }

  /// Whether DirBuff can't find it: deleted, moved to another disk, or moved to the Bin.
  public var isMissing: Bool { problem == .missing }

  /// Whether it's on a drive that isn't connected.
  public var isUnplugged: Bool { problem == .unreachable }

  /// Why no buff can go on it now, whatever it wears: "DirBuff can't find Scratch", "T7 Shuttle
  /// isn't connected"; nil while it's within reach.
  public var unreachableReason: String? {
    switch problem {
    case .missing: "DirBuff can't find \(name)"
    case .unreachable: "\(volumeName(path) ?? "Its drive") isn't connected"
    case .noAccess, nil: nil
    }
  }

  /// Whether the folder wears `buff` (paused buffs still count; one just taken off doesn't).
  public func wears(_ buff: Buff) -> Bool {
    buffs.contains { $0.buff == buff }
  }
}

/// What the main window shows: the sidebar's folders, the shelf of folder tiles, the Buffs page,
/// and the folder pages.
public struct MainState: Sendable, Equatable {
  public var folders: [MainFolder]
  /// Every folder added to DirBuff, needs-you first then by name: the shelf's order.
  public var shelfFolders: [FolderState]
  public var licenceLine: LicenceLine?
  /// Why no folder can be made Temporary right now; nil while it can.
  public var licenceRefusal: String?
  /// What the button beside that reason is called.
  public var buyTitle: String
  public var mayClean: Bool
  public var startupVolumeName: String
  public var protectedPaths: Set<String>

  public var needsYouCount: Int { shelfFolders.count(where: \.isNeedingYou) }

  /// The tiles whose folder name holds `query`, in shelf order.
  public func shelfFolders(matching query: String) -> [FolderState] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return shelfFolders }
    return shelfFolders.filter { $0.name.localizedStandardContains(trimmed) }
  }

  /// All Folders' subtitle: "6 folders · 1 needs you", "6 folders · all paused", or "6 folders".
  /// Paused only while some folder wears a buff the licence paused.
  public var shelfSubtitle: String {
    guard !shelfFolders.isEmpty else { return "No folders" }
    let total = folderCountWords(shelfFolders.count)
    if !mayClean && shelfFolders.contains(where: { !$0.buffs.isEmpty }) {
      return shelfFolders.count == 1 ? "\(total) · paused" : "\(total) · all paused"
    }
    let needing = needsYouCount
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
      if let reason = folder.unreachableReason {
        return AddBuffItem(buff: buff, isEnabled: false, subtitle: reason)
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
      let isReadable = report.problem == nil
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

private func isExternalVolumeRoot(_ path: String) -> Bool {
  let parts = path.split(separator: "/")
  return parts.count == 2 && parts[0] == "Volumes"
}
