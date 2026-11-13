import Foundation
import Testing

@testable import DirBuffKit

/// Restore Folder tells how far the download has got, for the run the popover shows.
@Suite(.runsRestic) struct BackupRestoreProgressTests {
  /// restic wrapped in a script that adds one progress line to a restore, as restic prints one
  /// each second of a long one; a restore of a few bytes ends before its first.
  private func restoringWithAStatusLine(_ fixture: BackupFixture) throws -> BackupBuff {
    let wrapper = fixture.scratch.url.appendingPathComponent("restic-with-progress")
    let real = try resticExecutable().path
    let status =
      #"{"message_type":"status","percent_done":0.5,"total_files":2,"files_restored":1,"total_bytes":10,"bytes_restored":5}"#
    try """
    #!/bin/sh
    case " $* " in *" restore "*) echo '\(status)' ;; esac
    exec '\(real)' "$@"

    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    return BackupBuff(
      engine: fixture.engine, storage: LocalRepository(folder: fixture.repositoryFolder),
      keychain: fixture.keychain, executable: wrapper,
      cacheDirectory: fixture.scratch.url.appendingPathComponent("cache"), home: fixture.home,
      qualityOfService: .userInitiated)
  }

  @Test func aRestoredFolderReportsItsProgress() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    try fixture.scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    let snapshot = try #require(try await fixture.snapshots(folderID).last)
    let backup = try restoringWithAStatusLine(fixture)
    let heard = Heard()

    let restored = try await backup.restoreFolder(
      folderID: folderID, backup: KeptBackup(snapshot), onProgress: { heard.add($0) })

    #expect(heard.all.map(\.filesRestored) == [1])
    #expect(heard.all.map(\.totalBytes) == [10])
    #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("a.txt").path))
  }
}

private final class Heard: @unchecked Sendable {
  private let lock = NSLock()
  private var progress: [RestoreProgress] = []

  var all: [RestoreProgress] { lock.withLock { progress } }

  func add(_ item: RestoreProgress) { lock.withLock { progress.append(item) } }
}
