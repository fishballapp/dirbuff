import DirBuffCore
import Foundation

/// The Buffs page: a card per buff, to drag onto a folder or add from its pop-up.
public struct BuffsPageState: Sendable, Equatable {
  public var cards: [BuffsPageCard]

  /// "4 buffs · 3 soon".
  public var subtitle: String {
    let soon = cards.count { !$0.buff.isAvailable }
    let total = cards.count == 1 ? "1 buff" : "\(cards.count) buffs"
    return soon == 0 ? total : "\(total) · \(soon) soon"
  }
}

/// A buff on the Buffs page: what it does, the folders that wear it, and where it can go on next.
public struct BuffsPageCard: Sendable, Equatable, Identifiable {
  public var id: Buff { buff }
  public var buff: Buff
  /// The folders that wear it, A to Z, each a pill that opens its page.
  public var folders: [SidebarFolder]
  /// Temporary's default setting: "Default: older than 90 days, to the Bin."
  public var startsAs: String?
  /// Add to Folder's items: every folder that doesn't wear it yet, A to Z.
  public var targets: [AddToFolderItem]
  /// Whether it can go on any folder now: not while it's Soon, or every buff is paused.
  public var canAdd: Bool

  /// "On 5 folders", "On 1 folder", "On no folders yet".
  public var wornBy: String {
    switch folders.count {
    case 0: "On no folders yet"
    case 1: "On 1 folder"
    default: "On \(folders.count) folders"
    }
  }
}

/// A folder in a buff's Add to Folder pop-up.
public struct AddToFolderItem: Sendable, Equatable, Identifiable {
  public var id: Int64 { folderID }
  public var folderID: Int64
  public var title: String
  public var isEnabled: Bool
  /// Why it can't take the buff: "Library is protected. DirBuff never clears it."
  public var subtitle: String?
}

extension MainState {
  /// Every buff, in order, with the folders the sidebar lists.
  public func buffsPage(binName: String = SystemBin.name) -> BuffsPageState {
    let rows = sidebarFolders
    return BuffsPageState(
      cards: Buff.allCases.map { buff in
        BuffsPageCard(
          buff: buff,
          folders: rows.filter { $0.folder.wears(buff) },
          startsAs: buff == .temporary
            ? "Default: \(lowercasingFirst(temporarySetting(TemporarySettings(), binName: binName)))."
            : nil,
          targets: rows.compactMap { row in
            guard let item = addBuffItems(for: row.folder).first(where: { $0.buff == buff })
            else { return nil }
            return AddToFolderItem(
              folderID: row.id, title: row.title, isEnabled: item.isEnabled,
              subtitle: item.subtitle)
          },
          canAdd: buff.isAvailable && mayClean)
      })
  }
}

private func lowercasingFirst(_ text: String) -> String {
  guard let first = text.first else { return text }
  return first.lowercased() + text.dropFirst()
}
