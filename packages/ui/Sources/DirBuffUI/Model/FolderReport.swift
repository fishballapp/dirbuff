import DirBuffCore
import DirBuffKit
import Foundation

/// A folder, where the registry found it or why it couldn't, and a reading of each buff it wears.
public struct FolderReport: Sendable {
  public var folder: Folder
  /// Found and readable, or why not; shared by every buff. A folder that wears nothing is found
  /// but never read.
  public var location: Result<URL, FolderProblem>
  /// One per buff it wears, in `Buff` order.
  public var buffs: [BuffReading]

  public init(folder: Folder, location: Result<URL, FolderProblem>, buffs: [BuffReading]) {
    self.folder = folder
    self.location = location
    self.buffs = buffs
  }

  /// Why the folder couldn't be found, or else why a buff couldn't read it; nil when all went well.
  public var problem: FolderProblem? { FolderProblem(location: location, buffs: buffs) }

  /// Temporary's wear, if the folder wears it.
  public var temporaryWear: Wear<TemporarySettings>? {
    buffs.lazy.compactMap { if case .temporary(let wear, _) = $0 { wear } else { nil } }.first
  }

  /// What reading Temporary found; nil when the folder doesn't wear it, or it wasn't read or
  /// couldn't be.
  public var temporaryStatus: TemporaryStatus? {
    buffs.lazy.compactMap {
      if case .temporary(_, .success(let status)) = $0 { status } else { nil }
    }.first
  }

  var name: String { URL(fileURLWithPath: folder.path).lastPathComponent }
}

/// One buff's wear on a folder and what reading it found: nil when it wasn't read, because the
/// folder wasn't found. Closed over the shipped buffs; each adds its case.
public enum BuffReading: Sendable {
  case temporary(Wear<TemporarySettings>, Result<TemporaryStatus, FolderProblem>?)

  public var buff: Buff {
    switch self {
    case .temporary: .temporary
    }
  }

  /// Why reading failed; nil when it was read or wasn't.
  var problem: FolderProblem? {
    switch self {
    case .temporary(_, .failure(let problem)?): problem
    case .temporary: nil
    }
  }
}

/// Why a folder couldn't be read.
public enum FolderProblem: Error, Sendable, Equatable {
  /// It's on a drive that isn't connected. Nothing for the user to fix here.
  case unreachable
  /// It was deleted, moved to another disk, or moved to the Bin: the user locates or removes it.
  case missing
  /// macOS took away DirBuff's access to it, which the user can give back.
  case noAccess

  /// Why a folder couldn't be found, or else why a buff couldn't read it; nil when all went well.
  public init?(location: Result<URL, FolderProblem>, buffs: [BuffReading]) {
    if case .failure(let problem) = location {
      self = problem
      return
    }
    guard let problem = buffs.lazy.compactMap(\.problem).first else { return nil }
    self = problem
  }

  /// Sorts what finding or reading a folder threw.
  public init(_ error: any Error) {
    if let failure = error as? Engine.Failure, failure == .folderMissing {
      self = .missing
      return
    }
    let error = error as NSError
    let denied =
      (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
      || (error.domain == NSPOSIXErrorDomain && [EACCES, EPERM].contains(Int32(error.code)))
    self = denied ? .noAccess : .unreachable
  }
}
