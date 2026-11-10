import Foundation

/// Where Backup's Google Drive stands for the whole Mac: the account, its storage, the one
/// repository in it, and whether the Mac may upload now. Every folder that wears Backup shares it,
/// so a failure here shows on each of them and the popover names them in one callout. A folder's
/// own state (its last run, the files it couldn't read) is in its `BackupStatus`.
public enum DriveState: Sendable, Equatable {
  /// Signed in, with room, the backup whole and a way to upload.
  case ready
  /// Backup is on but Google sign-in hasn't happened: the row waits, faded, and nothing is wrong.
  case notSignedIn
  /// Google no longer accepts DirBuff's access (revoked, or a token unused for six months).
  case signedOut
  /// Drive is full or within 1 GB of it.
  case full
  /// The repository's folder, or its `config`, was deleted in Drive.
  case backupGone
  /// The repository's folder is in Drive's Bin.
  case backupInBin
  /// The weekly check found a piece of the backup missing.
  case partMissing
  /// Nothing is wrong, but the Mac isn't to upload yet.
  case waiting(Wait)

  /// Why a backup waits, with nothing for the user to do.
  public enum Wait: Sendable, Equatable {
    case internet
    /// On cellular, a Personal Hotspot or in Low Data Mode.
    case wifi
    /// On battery below 20%.
    case power
    case lowPowerMode
    /// Google's daily upload cap or a rate limit; uploads resume at this time.
    case googleLimit(resumesAt: Date)
  }
}
