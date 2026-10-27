import DirBuffKit
import Foundation

/// A folder and what reading it found, or why it couldn't be read.
public struct FolderReport: Sendable {
  public var folder: Folder
  public var reading: Result<Engine.FolderStatus, FolderProblem>

  public init(folder: Folder, reading: Result<Engine.FolderStatus, FolderProblem>) {
    self.folder = folder
    self.reading = reading
  }

  public var status: Engine.FolderStatus? { try? reading.get() }

  var name: String { URL(fileURLWithPath: folder.path).lastPathComponent }
}

/// Why a folder couldn't be read.
public enum FolderProblem: Error, Sendable, Equatable {
  /// It was deleted, or it's on a drive that isn't connected. Nothing for the user to fix here.
  case unreachable
  /// macOS took away DirBuff's access to it, which the user can give back.
  case noAccess

  /// Sorts what reading a folder threw.
  public init(_ error: any Error) {
    let error = error as NSError
    let denied =
      (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
      || (error.domain == NSPOSIXErrorDomain && [EACCES, EPERM].contains(Int32(error.code)))
    self = denied ? .noAccess : .unreachable
  }
}
