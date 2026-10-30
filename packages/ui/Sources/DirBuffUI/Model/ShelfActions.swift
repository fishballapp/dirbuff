import Foundation

/// Everything the main window's folders and buffs can do, wired to the app by
/// `MainContainerView`. Each starts as a no-op, so previews and tests set only what they use.
public struct ShelfActions {
  /// + Folder and the sidebar's +: picks a folder to add, wearing nothing, and opens its page.
  public var addFolder: () -> Void = {}
  /// Add to Folder › Other Folder…: picks a folder to add the buff to.
  public var chooseFolderForBuff: (Buff) -> Void = { _ in }
  /// Puts a buff on a folder; returns whether it went on.
  public var addBuff: @MainActor (_ folderID: Int64, Buff) async -> Bool = { _, _ in false }
  /// Takes a buff straight back off, right after it was added: no alert, nothing to put back.
  public var undoAddBuff: (_ folderID: Int64, Buff) -> Void = { _, _ in }
  /// Takes a buff off, asking first: its settings will be forgotten.
  public var takeOff: (_ folderID: Int64, Buff) -> Void = { _, _ in }
  public var fix: (_ folderID: Int64, Fix) -> Void = { _, _ in }
  /// Asks where a missing folder went.
  public var locate: (_ folderID: Int64) -> Void = { _ in }
  /// Forgets a folder, asking first. Its files are left alone.
  public var removeFolder: (_ folderID: Int64) -> Void = { _ in }
  public var showInFinder: (_ folderID: Int64) -> Void = { _ in }
  /// Opens Settings at its Licence section.
  public var openLicenceSettings: () -> Void = {}
  public var buy: () -> Void = {}
  public var enterKey: () -> Void = {}
  public var checkLicence: () -> Void = {}

  public init() {}
}

extension ShelfActions {
  /// Puts `buff` on the folder without waiting to hear whether it went on: a menu or a click that
  /// shows nothing after.
  @MainActor
  func add(_ buff: Buff, to folderID: Int64) {
    Task { _ = await addBuff(folderID, buff) }
  }
}
