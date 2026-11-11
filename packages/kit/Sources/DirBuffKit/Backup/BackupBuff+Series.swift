import Foundation

extension BackupBuff {
  /// The series a Backup folder's snapshots are in, as `BackedUpFolder.series` names it: how a
  /// restore of this Mac's own folder finds its folder in the backup, whatever it is called now.
  public func series(of folderID: Int64) throws -> String? {
    try store.backupRecord(folderID: folderID)?.tag
  }
}
