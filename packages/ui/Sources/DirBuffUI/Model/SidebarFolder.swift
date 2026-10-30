import Foundation

/// A folder's row in the sidebar: its icon and mark, its name, and beneath it the symbols of the
/// buffs it wears, or "No buffs".
public struct SidebarFolder: Sendable, Equatable, Identifiable {
  public enum Condition: Sendable, Equatable {
    /// At rest or working: the symbols in Ink.
    case atRest
    /// A buff needs the user: the row on Amber Tint inside the Amber Edge, the badge at its end,
    /// and the symbols amber.
    case needsYou
    /// Its drive isn't connected: the icon fades, the symbols turn Quiet, and the row says so.
    /// There's nothing for the user to do, so no amber.
    case unplugged
    /// The licence paused every buff: the symbols turn Quiet.
    case paused
  }

  public var id: Int64 { folder.id }
  public var folder: FolderState
  /// The folder's name, and when another added folder shares it, its volume or parent:
  /// "Exports · T7 Shuttle".
  public var title: String
  public var condition: Condition

  /// The buffs it wears, in `Buff` order.
  public var buffs: [Buff] { folder.buffs.map(\.buff) }

  /// Under the name, beside the symbols or in their place.
  public var note: String? {
    if condition == .unplugged { return "Not connected" }
    return buffs.isEmpty ? "No buffs" : nil
  }
}

extension MainState {
  /// One row per folder, A to Z by title and never by state, so a row stays put when its folder
  /// starts or stops needing the user.
  public var sidebarFolders: [SidebarFolder] {
    let namesakes = Dictionary(grouping: shelfFolders) { $0.name.localizedLowercase }
    return shelfFolders.map { folder in
      let others = (namesakes[folder.name.localizedLowercase] ?? []).filter { $0.id != folder.id }
      return SidebarFolder(
        folder: folder,
        title: others.isEmpty
          ? folder.name : "\(folder.name) · \(qualifier(of: folder, among: others))",
        condition: sidebarCondition(folder))
    }
    .sorted { lhs, rhs in
      let byTitle = lhs.title.localizedStandardCompare(rhs.title)
      guard byTitle == .orderedSame else { return byTitle == .orderedAscending }
      return lhs.id < rhs.id
    }
  }

  /// Its volume, when no namesake shares that; otherwise the folder it sits in.
  private func qualifier(of folder: FolderState, among namesakes: [FolderState]) -> String {
    let volume = volume(of: folder.path)
    guard namesakes.contains(where: { self.volume(of: $0.path) == volume }) else { return volume }
    return URL(fileURLWithPath: folder.path).deletingLastPathComponent().lastPathComponent
  }

  /// "T7 Shuttle" for a folder under /Volumes, or the startup disk's name.
  private func volume(of path: String) -> String {
    let parts = path.split(separator: "/")
    guard parts.count >= 2, parts[0] == "Volumes" else { return startupVolumeName }
    return String(parts[1])
  }
}

private func sidebarCondition(_ folder: FolderState) -> SidebarFolder.Condition {
  if folder.isNeedingYou { return .needsYou }
  let pauses = folder.buffs.compactMap {
    if case .paused(let reason) = $0.state { return reason }
    return nil
  }
  if folder.isUnplugged || pauses.contains(where: \.isDriveUnplugged) { return .unplugged }
  return pauses.isEmpty ? .atRest : .paused
}

extension PauseReason {
  var isDriveUnplugged: Bool {
    if case .driveUnplugged = self { return true }
    return false
  }
}
