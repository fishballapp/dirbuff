import DirBuffCore

/// The folder + Buff's click adds to, with what each buff would do there.
public struct AddBuffTarget: Sendable, Equatable {
  public var folder: FolderState
  /// The folder's "Add a Buff to …" items: what it doesn't wear yet, and whether it can.
  public var items: [AddBuffItem]

  public init(folder: FolderState, items: [AddBuffItem]) {
    self.folder = folder
    self.items = items
  }
}

extension MainState {
  /// + Buff's target for `folder`: what each buff would do there.
  public func addBuffTarget(_ folder: FolderState) -> AddBuffTarget {
    AddBuffTarget(folder: folder, items: addBuffItems(for: folder))
  }
}

/// One buff in + Buff: what a click on it does, said at the row's end.
public struct AddBuffRow: Sendable, Equatable, Identifiable {
  public enum Offer: Sendable, Equatable {
    /// "Add to Screenshots" while the pointer is over it; a click adds it.
    case add(folderName: String)
    /// "✓ Added": the target already wears it.
    case added
    /// "Soon": this build can't put it on a folder.
    case soon
    /// Nothing to click: no folder is selected, or the target can't wear it. It still drags.
    case dragOnly
  }

  public var id: Buff { buff }
  public var buff: Buff
  public var offer: Offer

  /// Only a buff this build can put on a folder leaves + Buff.
  public var isDraggable: Bool { buff.isAvailable }

  /// Every buff, in order, as + Buff lists them for `target`.
  public static func all(for target: AddBuffTarget?) -> [AddBuffRow] {
    Buff.allCases.map { buff in
      AddBuffRow(buff: buff, offer: offer(buff, for: target))
    }
  }

  private static func offer(_ buff: Buff, for target: AddBuffTarget?) -> Offer {
    guard buff.isAvailable else { return .soon }
    guard let target else { return .dragOnly }
    if target.folder.wears(buff) { return .added }
    let canAdd = target.items.first(where: { $0.buff == buff })?.isEnabled ?? false
    return canAdd ? .add(folderName: target.folder.name) : .dragOnly
  }
}

/// What letting go of a buff over a tile does.
public enum BuffDropVerdict: Sendable, Equatable {
  /// It goes on: "Add Temporary to Scratch".
  case add(String)
  /// It doesn't, and why, in grey: "Temporary is already on Scratch".
  case refused(String)
  /// The folder is protected: the tile fades with "Protected" for as long as the buff is in the air.
  case protected

  /// Whether `buff` dropped on `folder` goes on, given the folder's "Add a Buff to …" items.
  public static func of(
    _ buff: Buff,
    on folder: FolderState,
    items: [AddBuffItem],
    mayClean: Bool
  ) -> BuffDropVerdict {
    if folder.wears(buff) { return .refused("\(buff.name) is already on \(folder.name)") }
    guard buff.isAvailable else { return .refused("\(buff.name) isn't ready yet") }
    guard mayClean else { return .refused("Every buff is paused") }
    // The items list every buff the folder doesn't wear; with the licence clear, only a protected
    // folder disables an available one.
    guard items.first(where: { $0.buff == buff })?.isEnabled == true else { return .protected }
    return .add("Add \(buff.name) to \(folder.name)")
  }
}

extension Disposal {
  /// Where things go, as the card after a drop says it: "Moved to the Bin", "Deleted permanently".
  public func addedLine(binName: String) -> String {
    switch self {
    case .bin: "Moved to the \(binName)"
    case .delete: "Deleted permanently"
    }
  }
}

extension TemporarySettings {
  /// The Age rule's days a pop-up offers, on the folder page and the card after a drop: a week,
  /// two, a month and three, with the days the folder has, in order.
  public static func ageDayChoices(including days: Int?) -> [Int] {
    Set([7, 14, 30, defaultMaxAgeDays] + (days.map { [$0] } ?? [])).sorted()
  }
}
