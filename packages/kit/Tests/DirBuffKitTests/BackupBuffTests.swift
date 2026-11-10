import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// Backup against a repository in a folder, with the real restic.
@Suite struct BackupBuffTests {
  let fixture: BackupFixture

  init() throws {
    fixture = try BackupFixture()
  }

  private var scratch: Scratch { fixture.scratch }
  private var backup: BackupBuff { fixture.backup }

  @Test func wearingKeepsTheSettingAndASeriesOfItsOwn() throws {
    let folderID = try fixture.addWearing("docs")
    let tag = try fixture.record(folderID).tag

    try backup.save(BackupSettings(history: .thirtyDays), folderID: folderID)
    try backup.setPausedByLicence(true, folderID: folderID)
    // Put on again: the pause lifts, the setting and the series stay.
    try backup.putOn(folderID: folderID)

    let wear = try #require(try backup.wear(folderID: folderID))
    #expect(wear.settings == BackupSettings(history: .thirtyDays))
    #expect(!wear.isPausedByLicence)
    #expect(try fixture.record(folderID).tag == tag)
    #expect(try backup.wearers().map(\.folderID) == [folderID])

    try backup.takeOff(folderID: folderID)
    #expect(try backup.wear(folderID: folderID) == nil)
    try backup.putOn(folderID: folderID)
    #expect(try fixture.record(folderID).tag != tag)
  }

  @Test func theFirstRunMakesTheRepositoryWithItsKeyBesideIt() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/a.txt", bytes: 100)
    try scratch.file("docs/deep/b.txt", bytes: 200)
    let runID = try fixture.store.beginRun(of: .backup, at: Date())

    let summary = try await fixture.run(folderID, runID: runID)

    #expect(summary == RunSummary(items: 2, bytes: summary.bytes, failures: 0))
    let key = try #require(try fixture.keychain.key())
    #expect(
      try String(
        contentsOf: fixture.repositoryFolder.appendingPathComponent("password.txt"),
        encoding: .utf8) == key)
    #expect(try backup.keyCustody() == .besideBackup)
    let snapshots = try await fixture.snapshots(folderID)
    #expect(snapshots.map(\.hostname) == [try Machine.id()])
    #expect(snapshots.map(\.id) == [try fixture.record(folderID).lastSnapshotID])
    #expect(
      try contents(of: try await fixture.restoredLatest(folderID)).keys.sorted() == [
        "a.txt", "deep/b.txt",
      ])
    // History keeps the run: opening the next one drops only empty runs.
    _ = try fixture.store.beginRun(of: .backup, at: Date())
    let recorded = try fixture.store.backupRuns(runID: runID)
    #expect(recorded.map(\.snapshotID) == snapshots.map(\.id))
    #expect(recorded.map(\.filesNew) == [2])
    let status = try backup.read(
      fixture.engine.locate(folderID: folderID), #require(try backup.wear(folderID: folderID)))
    #expect(status.lastSuccessAt != nil)
    #expect(status.lastError == nil)
  }

  @Test func whatEveryBackupLeavesOutAndWhatTheUserLeftOutAreNotSaved() async throws {
    let folderID = try fixture.addWearing("home")
    for path in [
      "keep.txt", "Library/Preferences/p.plist", "code/node_modules/x/i.js", "code/.venv/bin/py",
      "code/.next/c", "code/.turbo/c", "code/.terraform/c", "code/__pycache__/c.pyc",
      "code/.DS_Store", "code/main.swift", "cache/data", "excluded.db", "sticky/inside.txt",
      "Projects/old.zip", "Projects/new.zip", "a/odd*[name]$HOME/x", "b/odd*[name]$HOME",
      "c/#hash",
    ] {
      try scratch.file("home/" + path)
    }
    try Data((BackupDefaults.cacheDirectorySignature + "\n").utf8).write(
      to: fixture.home.appendingPathComponent("cache/CACHEDIR.TAG"))
    for path in ["excluded.db", "sticky"] {
      try setTimeMachineExclusion(on: fixture.home.appendingPathComponent(path))
    }
    try backup.leaveOut(.path("/Projects/old.zip/"), folderID: folderID)
    try backup.leaveOut(.name("odd*[name]$HOME"), folderID: folderID)
    try backup.leaveOut(.name("#hash"), folderID: folderID)

    try await fixture.run(folderID)

    let restored = try contents(of: try await fixture.restoredLatest(folderID)).keys.sorted()
    #expect(restored == ["Projects/new.zip", "cache/CACHEDIR.TAG", "code/main.swift", "keep.txt"])
    #expect(
      try backup.leftOut(folderID: folderID) == [
        .name("#hash"), .name("odd*[name]$HOME"), .path("Projects/old.zip"),
      ])
  }

  @Test func aFileThatCouldNotBeReadIsSkippedUntilItIsLeftOut() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/readable.txt")
    let locked = try scratch.file("docs/private/locked.txt")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
    }
    try #require(!FileManager.default.isReadableFile(atPath: locked.path), "Running as root")

    let summary = try await fixture.run(folderID)

    #expect(summary.failures == 1)
    let wear = try #require(try backup.wear(folderID: folderID))
    let located = try fixture.engine.locate(folderID: folderID)
    #expect(try backup.read(located, wear).skipped.map(\.path) == ["private/locked.txt"])
    #expect(try fixture.record(folderID).lastSnapshotID != nil)

    try backup.leaveOut(.path("private"), folderID: folderID)
    #expect(try backup.read(located, wear).skipped.isEmpty)
    #expect(try await fixture.run(folderID).failures == 0)
  }

  @Test func eachBackupRecordsWhatChangedAsVersions() async throws {
    let folderID = try fixture.addWearing("docs")
    let a = try scratch.file("docs/a.txt", bytes: 10)
    let b = try scratch.file("docs/sub/b.txt", bytes: 20)
    try await fixture.run(folderID)
    #expect(try fixture.store.backupVersions(folderID: folderID).isEmpty)

    try Data(count: 30).write(to: a)
    try FileManager.default.removeItem(at: b)
    try scratch.file("docs/sub/c.txt", bytes: 40)
    try await fixture.run(folderID)

    let snapshotID = try #require(try fixture.record(folderID).lastSnapshotID)
    let versions = try fixture.store.backupVersions(folderID: folderID)
    #expect(
      versions.map { "\($0.change) \($0.path) \($0.size.map(String.init) ?? "-")" } == [
        "changed a.txt 30", "removed sub/b.txt -", "added sub/c.txt 40",
      ])
    #expect(Set(versions.map(\.snapshotID)) == [snapshotID])
  }

  @Test func maintenanceThinsAFoldersHistoryOnceADay() async throws {
    let folderID = try fixture.addWearing("docs")
    let file = try scratch.file("docs/a.txt")
    // Within one hour, the latest 10 count, and the oldest while the history is younger than its
    // spans: so of 12, the second goes. b.txt is saved in the second and never changes after.
    for count in 1...12 {
      try Data(count: count).write(to: file)
      if count == 2 { try scratch.file("docs/b.txt") }
      try await fixture.run(folderID)
    }
    let today = Date()

    try await backup.maintain(now: today)

    let snapshots = try await fixture.snapshots(folderID).sorted { $0.time < $1.time }
    #expect(snapshots.count == 11)
    let versions = try fixture.store.backupVersions(folderID: folderID)
    // a.txt's second version went with the second snapshot; b.txt's is in the third too.
    #expect(versions.filter { $0.path == "a.txt" }.count == 10)
    #expect(
      versions.filter { $0.path == "b.txt" }.map(\.snapshotID) == [snapshots[1].id])

    try await fixture.run(folderID)
    try await backup.maintain(now: today)
    #expect(try await fixture.snapshots(folderID).count == 12)

    try await backup.maintain(now: today.addingTimeInterval(day))
    #expect(try await fixture.snapshots(folderID).count == 11)
    #expect(try await fixture.isHealthy())
  }

  @Test func aFolderWhoseSnapshotsAreGoneDoesNotStopMaintenance() async throws {
    let emptied = try fixture.addWearing("emptied")
    let gone = try fixture.addWearing("gone")
    try scratch.file("emptied/a.txt")
    try scratch.file("gone/b.txt")
    try await fixture.run(emptied)
    try await fixture.run(gone)
    try backup.takeOff(folderID: gone, isDeletingBackup: true)
    // Removed by something other than Backup: a repair, or by hand.
    try await fixture.restic().forget(snapshotIDs: try await fixture.snapshots(emptied).map(\.id))

    try await backup.maintain()

    #expect(try fixture.record(emptied).lastForgetAt != nil)
    #expect(try fixture.store.pendingBackupDeletions().isEmpty)
  }

  @Test func aFileThatBecameAFolderIsRemovedFromVersions() async throws {
    let folderID = try fixture.addWearing("docs")
    let file = try scratch.file("docs/report")
    try await fixture.run(folderID)
    try FileManager.default.removeItem(at: file)
    try scratch.file("docs/report/page.txt")

    try await fixture.run(folderID)

    let versions = try fixture.store.backupVersions(folderID: folderID)
    #expect(versions.map { "\($0.change) \($0.path)" } == ["removed report"])
  }

  @Test func takingBackupOffAndDeletingItsBackupForgetsAndPrunesOnlyItsSnapshots() async throws {
    let gone = try fixture.addWearing("gone")
    let kept = try fixture.addWearing("kept")
    try randomData(2_000_000).write(to: try scratch.file("gone/big.bin"))
    try scratch.file("kept/a.txt")
    try await fixture.run(gone)
    try await fixture.run(kept)
    let goneTag = try fixture.record(gone).resticTag

    try backup.takeOff(folderID: gone, isDeletingBackup: true)
    #expect(try backup.wear(folderID: gone) == nil)
    try await backup.maintain()

    let restic = try fixture.restic()
    #expect(try await restic.snapshots(tags: [goneTag]).isEmpty)
    #expect(try await fixture.snapshots(kept).count == 1)
    #expect(try fixture.store.pendingBackupDeletions().isEmpty)
    #expect(try fixture.store.backupAccount()?.lastPrunedAt != nil)
    #expect(try await fixture.isHealthy())
  }

  @Test func theRepositoryIsPrunedOnceAWeek() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    let now = Date()

    try await backup.maintain(now: now)
    #expect(try fixture.store.backupAccount()?.lastPrunedAt == nil)

    let nextWeek = now.addingTimeInterval(7 * day).wholeSeconds
    try await backup.maintain(now: nextWeek)
    #expect(try fixture.store.backupAccount()?.lastPrunedAt == nextWeek)
  }

  @Test func privateBackupTakesTheKeyAwayOnlyOnceTheUserConfirmsIt() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    let besideKey = try #require(try fixture.keychain.key())
    let passwordFile = fixture.repositoryFolder.appendingPathComponent("password.txt")

    let recoveryKey = try await backup.makeRecoveryKey()

    #expect(recoveryKey.wholeMatch(of: /([0-9A-HJKMNP-TV-Z]{5}-){5}[0-9A-HJKMNP-TV-Z]{5}/) != nil)
    // Shown, not yet confirmed: everything that opened the backup still does.
    try await expectBesideTheBackup(key: besideKey)

    try await backup.turnOnPrivateBackup(confirming: recoveryKey)

    #expect(try fixture.keychain.key() == recoveryKey)
    #expect(try backup.keyCustody() == .private)
    #expect(!exists(passwordFile))
    #expect(try await fixture.restic().keys().count == 1)
    await #expect {
      try await testRestic(in: scratch, password: besideKey).snapshots()
    } throws: { error in
      guard case ResticFailure.exited(.wrongPassword, _) = error else { return false }
      return true
    }
    #expect(try await fixture.run(folderID).failures == 0)

    try await backup.turnOffPrivateBackup()

    #expect(try backup.keyCustody() == .besideBackup)
    #expect(try String(contentsOf: passwordFile, encoding: .utf8) == recoveryKey)
  }

  @Test func aKeyThatWasNeverMadeOrIsMistypedChangesNothing() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    let besideKey = try #require(try fixture.keychain.key())

    // Confirmed before one was made.
    await #expect(throws: BackupBuff.Failure.recoveryKeyDoesNotOpen) {
      try await backup.turnOnPrivateBackup(confirming: RecoveryKey.make())
    }
    try await expectBesideTheBackup(key: besideKey)

    // Typed back wrong.
    let recoveryKey = try await backup.makeRecoveryKey()
    await #expect(throws: BackupBuff.Failure.recoveryKeyDoesNotOpen) {
      try await backup.turnOnPrivateBackup(confirming: String(recoveryKey.dropLast()) + "0")
    }
    try await expectBesideTheBackup(key: besideKey)
  }

  @Test func aRecoveryKeyNeverConfirmedLeavesTheBackupAsItWas() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    let besideKey = try #require(try fixture.keychain.key())

    let abandoned = try await backup.makeRecoveryKey()
    try scratch.file("docs/b.txt")
    try await fixture.run(folderID)
    try await backup.maintain()

    try await expectBesideTheBackup(key: besideKey)
    // `password.txt` alone opens it, as on a new Mac.
    let password = try String(
      contentsOf: fixture.repositoryFolder.appendingPathComponent("password.txt"), encoding: .utf8)
    #expect(try await testRestic(in: scratch, password: password).snapshots().count == 2)

    // Turning it on later starts again, and the abandoned key goes with the old one.
    let recoveryKey = try await backup.makeRecoveryKey()
    try await backup.turnOnPrivateBackup(confirming: recoveryKey)
    #expect(try await fixture.restic().keys().count == 1)
    await #expect(throws: ResticFailure.self) {
      try await testRestic(in: scratch, password: abandoned).snapshots()
    }
  }

  @Test func aNewRecoveryKeyStopsTheOldOneOpeningTheBackup() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    let first = try await backup.makeRecoveryKey()
    try await backup.turnOnPrivateBackup(confirming: first)

    let second = try await backup.makeRecoveryKey()
    // Shown, not yet confirmed: the first still opens it, and a run doesn't take the second away.
    try await fixture.run(folderID)
    #expect(try await testRestic(in: scratch, password: first).keys().count == 2)
    try await backup.turnOnPrivateBackup(confirming: second)

    #expect(try fixture.keychain.key() == second)
    #expect(try await fixture.restic().keys().count == 1)
    await #expect {
      try await testRestic(in: scratch, password: first).snapshots()
    } throws: { error in
      guard case ResticFailure.exited(.wrongPassword, _) = error else { return false }
      return true
    }
  }

  /// The key is beside the backup, the Keychain holds it, and it still opens the repository.
  private func expectBesideTheBackup(key: String) async throws {
    #expect(try backup.keyCustody() == .besideBackup)
    #expect(try fixture.keychain.key() == key)
    #expect(
      try String(
        contentsOf: fixture.repositoryFolder.appendingPathComponent("password.txt"),
        encoding: .utf8) == key)
    #expect(try await testRestic(in: scratch, password: key).keys().contains { $0.isCurrent })
  }

  @Test func aSwitchToPrivateCutShortIsFinishedByTheNextCommand() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    // As `turnOnPrivateBackup` leaves it when the app quits just after the custody changed.
    _ = try await fixture.restic().addKey(newPassword: "the new key")
    try fixture.keychain.save("the new key")
    try fixture.store.setKeyCustody(.private)

    try await fixture.run(folderID)

    #expect(!exists(fixture.repositoryFolder.appendingPathComponent("password.txt")))
    #expect(try await fixture.restic().keys().count == 1)
  }

  @Test func runsOfTwoFoldersAtOnceTakeTurns() async throws {
    let first = try fixture.addWearing("first")
    let second = try fixture.addWearing("second")
    try scratch.file("first/a.txt")
    try scratch.file("second/b.txt")

    let backup = backup
    let runs = try [first, second].map { folderID in
      (
        try fixture.engine.locate(folderID: folderID),
        try #require(try backup.wear(folderID: folderID))
      )
    }
    let context = RunContext(runID: nil, scheduledAt: Date())
    async let firstRun = backup.run(runs[0].0, runs[0].1, context: context)
    async let secondRun = backup.run(runs[1].0, runs[1].1, context: context)
    let summaries = try await [firstRun, secondRun]

    #expect(summaries.map(\.items) == [1, 1])
    #expect(try await fixture.restic().snapshots().count == 2)
  }

  @Test func aFolderTheLicencePausedIsNotBackedUp() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/a.txt")
    try backup.setPausedByLicence(true, folderID: folderID)

    #expect(try await fixture.run(folderID) == RunSummary(items: 0, bytes: 0, failures: 0))
    #expect(!exists(fixture.repositoryFolder.appendingPathComponent("config")))
  }

  @Test func aFailedRunIsRecordedForHistoryAndCountsTowardsFailing() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    // The repository's key is gone from the Mac and from beside the backup.
    try fixture.keychain.save("not the key")
    try FileManager.default.removeItem(
      at: fixture.repositoryFolder.appendingPathComponent("password.txt"))
    let runID = try fixture.store.beginRun(of: .backup, at: Date())

    await #expect(throws: BackupBuff.Failure.keyMissing) {
      try await fixture.run(folderID, runID: runID)
    }
    await #expect(throws: BackupBuff.Failure.keyMissing) { try await fixture.run(folderID) }

    let record = try fixture.record(folderID)
    #expect(record.failedRunsInARow == 2)
    #expect(record.failingSince != nil)
    #expect(record.lastError?.contains("keyMissing") == true)
    #expect(try fixture.store.backupRuns(runID: runID).map(\.snapshotID) == [nil])
  }

  @Test func aStaleKeychainKeyGivesWayToTheKeyBesideTheBackup() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    let besideKey = try #require(try fixture.keychain.key())
    try fixture.keychain.save("a key the repository never had")

    #expect(try await fixture.run(folderID).failures == 0)

    #expect(try fixture.keychain.key() == besideKey)
    #expect(try await fixture.snapshots(folderID).count == 2)
  }

  @Test func aPrivateBackupWithAStaleKeychainKeyNeedsTheRecoveryKey() async throws {
    let folderID = try fixture.addWearing("docs")
    try scratch.file("docs/a.txt")
    try await fixture.run(folderID)
    try await backup.turnOnPrivateBackup(confirming: try await backup.makeRecoveryKey())
    try fixture.keychain.save("a key the repository never had")

    await #expect(throws: BackupBuff.Failure.keyMissing) { try await fixture.run(folderID) }
  }

  @Test func aRunWhoseSeriesWentWhileItRanRecordsNothing() throws {
    let folderID = try fixture.addWearing("docs")
    let old = try fixture.record(folderID)
    // Taken off, with its backup to delete, and put on again while the run waited on restic.
    try backup.takeOff(folderID: folderID, isDeletingBackup: true)
    try backup.putOn(folderID: folderID)
    let runID = try fixture.store.beginRun(of: .backup, at: Date())

    try fixture.store.recordBackup(
      SavedBackup(
        snapshotID: "old", savedAt: Date(), filesNew: 1, filesChanged: 1, bytesAdded: 10,
        skipped: [SkippedFile(path: "a", reason: "locked")],
        versions: [SavedVersion(path: "b", change: .changed, size: 1)], cloudOnlyCount: 0),
      for: old, runID: runID, at: Date())
    try fixture.store.recordBackupFailure("boom", for: old, runID: runID, at: Date())

    let new = try fixture.record(folderID)
    #expect(new.tag != old.tag)
    #expect(new.lastSnapshotID == nil)
    #expect(new.lastError == nil)
    #expect(new.failedRunsInARow == 0)
    #expect(new.skippedCount == 0)
    #expect(try fixture.store.backupVersions(folderID: folderID).isEmpty)
    #expect(try fixture.store.backupRuns(runID: runID).isEmpty)
  }

  @Test func aNameToLeaveOutCantHoldASlash() throws {
    let folderID = try fixture.addWearing("docs")
    #expect(throws: BackupBuff.Failure.nameWithSlash("a/b")) {
      try backup.leaveOut(.name("a/b"), folderID: folderID)
    }
  }

  @Test(arguments: [
    (
      BackupHistory.forever,
      [
        "--keep-last", "10", "--keep-yearly", "unlimited", "--keep-within-hourly", "48h",
        "--keep-within-daily", "30d", "--keep-within-weekly", "84d", "--keep-within-monthly", "24m",
      ]
    ),
    (
      .oneYear,
      [
        "--keep-last", "10", "--keep-within-hourly", "48h", "--keep-within-daily", "30d",
        "--keep-within-weekly", "84d", "--keep-within-monthly", "1y",
      ]
    ),
    (
      .thirtyDays,
      [
        "--keep-last", "10", "--keep-within-hourly", "48h", "--keep-within-daily", "30d",
      ]
    ),
  ])
  func eachHistoryKeepsWhatItSays(history: BackupHistory, arguments: [String]) {
    #expect(BackupBuff.policy(history).arguments == arguments)
  }
}

func setTimeMachineExclusion(on url: URL) throws {
  let value = Data("com.apple.backupd".utf8)
  let result = value.withUnsafeBytes { bytes in
    setxattr(
      url.path, BackupDefaults.timeMachineExclusionAttribute, bytes.baseAddress, bytes.count, 0, 0)
  }
  guard result == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
}
