import Foundation

/// Everything the shelf and its tiles can do, wired to the app by `MainContainerView`. Each starts
/// as a no-op, so previews and tests set only what they use.
public struct ShelfActions {
  /// + Buff's Choose Folder…: picks a folder to add the buff to.
  public var chooseFolderForBuff: (Buff) -> Void = { _ in }
  public var addBuff: (_ folderID: Int64, Buff) -> Void = { _, _ in }
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
