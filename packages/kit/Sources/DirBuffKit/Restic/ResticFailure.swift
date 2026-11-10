import Foundation

/// What restic's exit status says.
public enum ResticExit: Equatable, Sendable {
  case success
  /// The command failed; its message says why.
  case failed
  case goRuntimeError
  /// `backup` couldn't read some of what it was told to save (the snapshot was still made), or
  /// `forget` couldn't remove a snapshot.
  case incomplete
  case repositoryMissing
  case lockFailed
  case wrongPassword
  /// Stopped by a signal.
  case cancelled
  /// A code added to restic since. Treat it as a failure.
  case other(Int32)

  public init(code: Int32) {
    switch code {
    case 0: self = .success
    case 1: self = .failed
    case 2: self = .goRuntimeError
    case 3: self = .incomplete
    case 10: self = .repositoryMissing
    case 11: self = .lockFailed
    case 12: self = .wrongPassword
    case 130: self = .cancelled
    default: self = .other(code)
    }
  }
}

/// Why a restic command didn't give a result.
public enum ResticFailure: Error, Equatable, Sendable {
  /// restic ran and exited with a failure. `message` is the one it printed last.
  case exited(ResticExit, message: String)
  /// DirBuff stopped restic for going quiet or running too long.
  case stalled(StallLimit)
  /// restic never started, or its output couldn't be read as the command promised.
  case unusable(String)
}

/// When DirBuff gives up on a running restic.
public enum StallLimit: Equatable, Sendable {
  /// Nothing moved for this long. restic prints a status every second whether or not it did, so
  /// this counts the files and bytes in them, not the messages.
  case noProgress(for: Duration)
  /// The command has run for this long, however it is doing.
  case wallClock(Duration)

  public var duration: Duration {
    switch self {
    case .noProgress(let duration), .wallClock(let duration): duration
    }
  }
}
