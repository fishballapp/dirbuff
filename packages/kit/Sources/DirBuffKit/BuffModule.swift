import DirBuffCore
import Foundation

/// A capability a folder wears. Each buff owns its table (settings are columns), its schedule, its
/// reading and its run. The folder registry (bookmark, path, missing, access) stays in `Engine`.
public protocol BuffModule: Sendable {
  associatedtype Settings: Sendable & Equatable
  associatedtype Reading: Sendable

  var buff: Buff { get }
  var schedule: BuffSchedule { get }
  /// What a folder starts with when the buff goes on it.
  var defaultSettings: Settings { get }

  /// Why the buff can't go on the folder at `url`, or nil. Putting it on there throws this.
  func refusal(for url: URL) -> Refusal?
  func wear(folderID: Int64) throws -> Wear<Settings>?
  /// Every folder that wears it, paused ones included, in the order the folders were added.
  func wearers() throws -> [Wear<Settings>]
  /// Puts the buff on with its default settings. On a folder that wears it already, keeps the
  /// settings and lifts a licence pause. Throws the refusal for a folder it can't go on.
  func putOn(folderID: Int64, now: Date) throws
  func save(_ settings: Settings, folderID: Int64, now: Date) throws
  /// Forgets the settings at once; works on a folder DirBuff can't reach.
  func takeOff(folderID: Int64) throws
  /// Pauses or resumes the buff when the trial or licence ends or comes back, keeping its
  /// settings; works on a folder DirBuff can't reach.
  func setPausedByLicence(_ isPaused: Bool, folderID: Int64) throws

  /// What every surface shows. Changes nothing.
  func read(_ folder: LocatedFolder, _ wear: Wear<Settings>, now: Date) async throws -> Reading
  /// Does the job once. Runs of different buffs may overlap, on one folder too.
  func run(_ folder: LocatedFolder, _ wear: Wear<Settings>, context: RunContext) async throws
    -> RunSummary
}

/// A folder the registry found, at the URL its bookmark resolved to.
public struct LocatedFolder: Sendable {
  public var folder: Folder
  public var url: URL

  public init(folder: Folder, url: URL) {
    self.folder = folder
    self.url = url
  }
}

/// Why a buff won't go on a folder.
public enum Refusal: Error, Sendable, Equatable {
  /// A folder DirBuff never clears (`protectedRoots`): the home folder, Library, a system folder
  /// or the top of a drive.
  case protectedFolder
}
