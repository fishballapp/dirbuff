import DirBuffCore
import Foundation

/// Finder's right-click item (`DirBuff: Add Buff ›` or `DirBuff: Buffs ›`) and the items inside its
/// submenu.
public struct FinderMenu: Sendable, Equatable {
  public var title: String
  public var items: [FinderMenuItem]

  public init(title: String, items: [FinderMenuItem]) {
    self.title = title
    self.items = items
  }

  /// **DirBuff: Add Buff ›** on a folder that wears no buff. Temporary stays enabled even while
  /// the licence doesn't allow cleaning: choosing it opens DirBuff's Settings window in front.
  public static func addBuff(
    folderName: String,
    isProtected: Bool,
    binName: String = SystemBin.name
  ) -> FinderMenu {
    FinderMenu(
      title: "DirBuff: Add Buff",
      items: [
        temporaryAddItem(folderName: folderName, isProtected: isProtected, binName: binName),
        soonItem(.backup),
        .separator,
        soonItem(.organise),
        soonItem(.search),
      ]
    )
  }

  /// **DirBuff: Buffs ›** on a folder that wears at least one buff.
  public static func buffs(
    folderName: String,
    worn: [FinderBuff],
    binName: String = SystemBin.name
  ) -> FinderMenu {
    var items: [FinderMenuItem] = [.sectionHeader("\(folderName) wears")]
    for entry in worn {
      items.append(
        FinderMenuItem(
          title: "\(entry.buff.name) \u{00b7} \(entry.setting)",
          subtitle: entry.nextEvent,
          buff: entry.buff,
          action: .openFolder,
          isEnabled: true
        )
      )
      if entry.buff == .temporary {
        items.append(FinderMenuItem(title: "Change\u{2026}", action: .change))
        items.append(
          FinderMenuItem(title: "What's Cleared Next\u{2026}", action: .whatsClearedNext))
        items.append(FinderMenuItem(title: "Take Temporary Off", action: .takeTemporaryOff))
      }
    }

    let wornSet = Set(worn.map(\.buff))
    let remaining = Buff.allCases.filter { !wornSet.contains($0) }
    if !remaining.isEmpty {
      items.append(.separator)
      items.append(.sectionHeader("Add"))
      for buff in remaining {
        items.append(soonItem(buff))
      }
    }

    items.append(.separator)
    items.append(FinderMenuItem(title: "Open in DirBuff", action: .openFolder))
    return FinderMenu(title: "DirBuff: Buffs", items: items)
  }

  private static func temporaryAddItem(
    folderName: String,
    isProtected: Bool,
    binName: String
  ) -> FinderMenuItem {
    if isProtected {
      return FinderMenuItem(
        title: Buff.temporary.name,
        subtitle: "\(folderName) is protected. DirBuff never clears it.",
        buff: .temporary,
        action: nil,
        isEnabled: false
      )
    }
    return FinderMenuItem(
      title: Buff.temporary.name,
      subtitle:
        "Files are cleared after \(days(TemporarySettings.defaultMaxAgeDays)), moved to the \(binName)",
      buff: .temporary,
      action: .addTemporary,
      isEnabled: true
    )
  }

  private static func soonItem(_ buff: Buff) -> FinderMenuItem {
    FinderMenuItem(
      title: buff.name,
      subtitle: "Soon",
      buff: buff,
      action: nil,
      isEnabled: false
    )
  }
}

/// One row in Finder's right-click submenu.
public struct FinderMenuItem: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case item
    case sectionHeader
    case separator
  }

  public var kind: Kind
  public var title: String
  public var subtitle: String?
  public var buff: Buff?
  public var action: FinderAction?
  public var isEnabled: Bool

  public init(
    kind: Kind = .item,
    title: String,
    subtitle: String? = nil,
    buff: Buff? = nil,
    action: FinderAction? = nil,
    isEnabled: Bool = true
  ) {
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.buff = buff
    self.action = action
    self.isEnabled = isEnabled
  }

  public static let separator = FinderMenuItem(kind: .separator, title: "", isEnabled: false)

  public static func sectionHeader(_ title: String) -> FinderMenuItem {
    FinderMenuItem(kind: .sectionHeader, title: title, isEnabled: false)
  }
}
