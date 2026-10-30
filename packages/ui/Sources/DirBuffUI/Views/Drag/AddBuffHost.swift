import SwiftUI

/// Where a dragged buff and the folders it can land on meet: the buff in the air, the folder under
/// it (a tile, a sidebar row, a folder's page), the card after a drop, and what only the app can do,
/// set once at launch. A drag can start in one window (the welcome window) and land in another, so
/// there is one for the whole app, `shared`; previews draw their own.
@MainActor
@Observable
public final class AddBuffHost {
  public static let shared = AddBuffHost()

  /// A buff dropped on a folder, whose card says what it will do until Undo or Done.
  public struct Added: Sendable, Equatable {
    public var buff: Buff
    public var folderID: Int64

    public init(buff: Buff, folderID: Int64) {
      self.buff = buff
      self.folderID = folderID
    }
  }

  /// The buff being dragged, from the Buffs page, a folder's page or the welcome window.
  public var draggedBuff: Buff?
  /// The folder under the dragged buff.
  public var dropFolderID: Int64?
  public var added: Added?

  /// Puts a buff dropped on a folder in Finder on that folder.
  @ObservationIgnored public var addToFinderFolder: (Buff, URL) -> Void = { _, _ in }
  /// Sets a folder's Age rule to a number of days, from the drop card's pop-up.
  @ObservationIgnored public var setMaxAge: (_ folderID: Int64, _ days: Int) -> Void = { _, _ in }

  public init(draggedBuff: Buff? = nil, dropFolderID: Int64? = nil, added: Added? = nil) {
    self.draggedBuff = draggedBuff
    self.dropFolderID = dropFolderID
    self.added = added
  }
}

extension EnvironmentValues {
  /// The app's `AddBuffHost.shared`, unless a preview draws its own.
  public var addBuffHost: AddBuffHost {
    get { self[AddBuffHostKey.self] }
    set { self[AddBuffHostKey.self] = newValue }
  }
}

private struct AddBuffHostKey: EnvironmentKey {
  // SwiftUI reads the environment on the main actor.
  static var defaultValue: AddBuffHost { MainActor.assumeIsolated { .shared } }
}
