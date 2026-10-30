import DirBuffKit
import Foundation

/// A folder and what reading it found, or why it couldn't be found or read. A folder that wears no
/// buff is found but not read: its reading succeeds with no status.
public struct FolderReport: Sendable {
  public var folder: Folder
  public var reading: Result<Engine.FolderStatus?, FolderProblem>

  public init(folder: Folder, reading: Result<Engine.FolderStatus?, FolderProblem>) {
    self.folder = folder
    self.reading = reading
  }

  /// What reading it found; nil when it wasn't read or couldn't be.
  public var status: Engine.FolderStatus? { (try? reading.get()) ?? nil }

  /// Why reading it failed; nil when it was read.
  public var problem: FolderProblem? {
    if case .failure(let problem) = reading { return problem }
    return nil
  }

  var name: String { URL(fileURLWithPath: folder.path).lastPathComponent }
}

/// Why a folder couldn't be read.
public enum FolderProblem: Error, Sendable, Equatable {
  /// It's on a drive that isn't connected. Nothing for the user to fix here.
  case unreachable
  /// It was deleted, moved to another disk, or moved to the Bin: the user locates or removes it.
  case missing
  /// macOS took away DirBuff's access to it, which the user can give back.
  case noAccess

  /// Sorts what reading a folder threw.
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
