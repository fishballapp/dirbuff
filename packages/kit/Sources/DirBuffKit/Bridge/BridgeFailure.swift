import Foundation

/// Why restic's command through the bridge failed, when the cause was Drive's: thrown by
/// `DriveBridge.serving` in place of restic's own failure, which only says a request failed.
public enum BridgeFailure: Error, Equatable, Sendable {
  case drive(DriveProblem)
  /// The account has uploaded as much as Google allows in a day (as the bridge counts it, or
  /// as Google said). Uploads can go on at `until`.
  case uploadPaused(until: Date)
}

/// What a request to the bridge needs of Drive, for deciding which ones a failure stops.
enum DriveUse: Sendable {
  case read, upload, delete
  /// Locks and folders: few bytes or none, and every command takes a lock and refreshes it while
  /// it runs, so they go on while uploads are paused (Drive full, the daily limit), for restic to
  /// take its lock off cleanly.
  case bookkeeping
}

extension BridgeFailure {
  /// The status restic is answered with, and the reason phrase it prints after it. restic gives
  /// up at once on 401, 403, 404, 416 and 507, and retries anything else for up to 15 minutes;
  /// `DriveClient` has already retried what waiting can fix, so only a checksum mismatch, which a
  /// fresh upload can fix, is left for restic to retry.
  var status: (code: Int, reason: String) {
    switch self {
    case .uploadPaused: (507, "Daily upload limit reached")
    case .drive(let problem):
      switch problem {
      case .signedOut: (401, "Signed out of Google Drive")
      case .storageFull: (507, "Google Drive is full")
      case .dailyUploadLimit: (507, "Daily upload limit reached")
      case .notFound: (404, "Not in Google Drive")
      case .rateLimited: (403, "Google Drive is limiting requests")
      case .unreachable: (403, "Google Drive can't be reached")
      case .checksumMismatch: (500, "Google Drive stored other bytes")
      case .rejected: (403, "Google Drive refused the request")
      }
    }
  }

  /// The requests this failure fails too, for the rest of the command, without asking Drive
  /// again: restic would otherwise go on, and each request would wait out `DriveClient`'s
  /// retries before failing the same way.
  var stops: Set<DriveUse> {
    switch self {
    case .uploadPaused: [.upload]
    case .drive(let problem):
      switch problem {
      case .signedOut, .rateLimited, .unreachable: [.read, .upload, .bookkeeping, .delete]
      // An upload's 404 is the repository's folder gone from Drive.
      case .storageFull, .dailyUploadLimit, .notFound: [.upload]
      case .checksumMismatch, .rejected: []
      }
    }
  }
}
