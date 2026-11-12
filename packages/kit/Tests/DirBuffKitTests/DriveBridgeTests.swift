import Foundation
import Testing

@testable import DirBuffKit

/// The pinned, unmodified restic, through the bridge, on the in-memory Drive. Each command gets a
/// bridge of its own, as the app runs them.
@Suite struct DriveBridgeTests {
  @Test func everyCommandBackupNeedsWorksThroughTheBridge() async throws {
    let fixture = try await BridgeFixture()
    let (bridge, restic) = (fixture.bridge, fixture.restic)
    let source = try fixture.source()
    let notes = source.appendingPathComponent("notes.txt")

    let repositoryID = try await bridge.serving(restic) { try await $0.createRepository() }
    #expect(repositoryID.count == 64)

    let first = try await bridge.serving(restic) {
      try await $0.backup(source, tags: ["folder=docs"], host: "test-mac")
    }
    #expect(first.isComplete)
    #expect(first.summary.filesNew == 2)

    try Data("second".utf8).write(to: notes)
    let second = try await bridge.serving(restic) {
      try await $0.backup(source, tags: ["folder=docs"], host: "test-mac")
    }
    #expect(second.summary.filesChanged == 1)
    #expect(second.summary.filesUnmodified == 1)

    let snapshots = try await bridge.serving(restic) { try await $0.snapshots() }
    #expect(snapshots.count == 2)

    let checked = try await bridge.serving(restic) {
      try await $0.check(readDataSubset: "100%", wallClockLimit: .seconds(120))
    }
    #expect(checked.isHealthy)

    let target = try fixture.scratch.folder("restored")
    let restored = try await bridge.serving(restic) {
      try await $0.restore(snapshot: second.summary.snapshotId ?? "latest", to: target)
    }
    #expect(restored.filesRestored >= 2)
    #expect(
      try String(contentsOf: target.appendingPathComponent("notes.txt"), encoding: .utf8)
        == "second")
    #expect(
      try Data(contentsOf: target.appendingPathComponent("photo.raw"))
        == Data(contentsOf: source.appendingPathComponent("photo.raw")))

    let groups = try await bridge.serving(restic) {
      try await $0.forget(keeping: ForgetPolicy(last: 1), tags: ["folder=docs"])
    }
    #expect(groups.flatMap(\.remove).map(\.id) == [first.summary.snapshotId].compactMap { $0 })
    try await bridge.serving(restic) { try await $0.prune(wallClockLimit: .seconds(120)) }

    let afterPrune = try await bridge.serving(restic) {
      try await $0.check(readDataSubset: "100%", wallClockLimit: .seconds(120))
    }
    #expect(afterPrune.isHealthy)
    #expect(try await bridge.serving(restic) { try await $0.snapshots() }.count == 1)
    // Every lock was taken off again.
    #expect(try await fixture.filesOnDrive().keys.filter { $0.hasPrefix("locks/") }.isEmpty)
  }

  @Test func restoreNeedsNoDirBuffOnceTheFolderIsDownloaded() async throws {
    let fixture = try await BridgeFixture()
    let source = try fixture.source()
    _ = try await fixture.bridge.serving(fixture.restic) { try await $0.createRepository() }
    let backup = try await fixture.bridge.serving(fixture.restic) {
      try await $0.backup(source, host: "test-mac")
    }

    let downloaded = fixture.scratch.url.appendingPathComponent("Test Mac")
    try await fixture.download(to: downloaded)
    let entries = try FileManager.default.contentsOfDirectory(atPath: downloaded.path).sorted()
    #expect(entries == ["config", "data", "index", "keys", "locks", "snapshots"])
    let shards = try FileManager.default.contentsOfDirectory(
      atPath: downloaded.appendingPathComponent("data").path)
    #expect(Set(shards) == Set((0...255).map { String(format: "%02x", $0) }))

    var stock = fixture.restic
    stock.repository = downloaded.path
    let snapshots = try await stock.snapshots()
    #expect(snapshots.map(\.id) == [backup.summary.snapshotId].compactMap { $0 })
    #expect(try await stock.check(readDataSubset: "100%", wallClockLimit: .seconds(120)).isHealthy)
    let target = try fixture.scratch.folder("restored")
    _ = try await stock.restore(snapshot: "latest", to: target)
    #expect(
      try Data(contentsOf: target.appendingPathComponent("photo.raw"))
        == Data(contentsOf: source.appendingPathComponent("photo.raw")))
  }

  @Test func aPackLostInDriveIsFoundOnceTheTableIsRebuilt() async throws {
    let fixture = try await BridgeFixture()
    let (bridge, restic) = (fixture.bridge, fixture.restic)
    let source = try fixture.source()
    _ = try await bridge.serving(restic) { try await $0.createRepository() }
    _ = try await bridge.serving(restic) { try await $0.backup(source) }

    // The largest pack holds the file's bytes; `check` without reading data doesn't open it.
    let packs = try await fixture.filesOnDrive().filter { $0.key.hasPrefix("data/") }.values
    let lost = try #require(packs.max { ($0.size ?? 0) < ($1.size ?? 0) })
    await fixture.drive.remove(lost.id)

    let stale = try await bridge.serving(restic) {
      try await $0.check(wallClockLimit: .seconds(120))
    }
    #expect(stale.isHealthy)

    try await bridge.rebuildTable()
    let rebuilt = try await bridge.serving(restic) {
      try await $0.check(wallClockLimit: .seconds(120))
    }
    #expect(!rebuilt.isHealthy)
  }

  @Test func aFullDriveFailsTheBackupAndSaysSo() async throws {
    let fixture = try await BridgeFixture(drive: InMemoryDrive(pageSize: 100, limitBytes: 100_000))
    let source = try fixture.source()
    _ = try await fixture.bridge.serving(fixture.restic) { try await $0.createRepository() }

    await #expect(throws: BridgeFailure.drive(.storageFull)) {
      try await fixture.bridge.serving(fixture.restic) { try await $0.backup(source) }
    }
    // Deleting still works when Drive is full, so restic took its lock off.
    #expect(try await fixture.filesOnDrive().keys.filter { $0.hasPrefix("locks/") }.isEmpty)
  }

  @Test func signingOutFailsTheCommandAndSaysSo() async throws {
    let fixture = try await BridgeFixture()
    let source = try fixture.source()
    _ = try await fixture.bridge.serving(fixture.restic) { try await $0.createRepository() }

    await fixture.drive.failNextCall(with: .signedOut)
    await fixture.drive.clearCalls()
    await #expect(throws: BridgeFailure.drive(.signedOut)) {
      try await fixture.bridge.serving(fixture.restic) { try await $0.backup(source) }
    }
    // Once signed out, nothing more was asked of Drive.
    #expect(await fixture.drive.calls == ["upload"])
  }

  @Test func theDailyLimitPausesUploadsUntilEnoughOfTheDayHasPassed() async throws {
    let fixture = try await BridgeFixture(dailyUploadLimit: 1_000_000)
    let source = try fixture.source()
    _ = try await fixture.bridge.serving(fixture.restic) { try await $0.createRepository() }

    await #expect(
      throws: BridgeFailure.uploadPaused(until: BridgeFixture.now.addingTimeInterval(86_400))
    ) {
      try await fixture.bridge.serving(fixture.restic) { try await $0.backup(source) }
    }
  }

  @Test func googlesOwnDailyLimitPausesUploadsToo() async throws {
    let fixture = try await BridgeFixture()
    let source = try fixture.source()
    _ = try await fixture.bridge.serving(fixture.restic) { try await $0.createRepository() }

    await fixture.drive.failNextCall(with: .dailyUploadLimit)
    // The repository's first upload was at `now`, so Google's rolling day ends a day after it.
    await #expect(
      throws: BridgeFailure.uploadPaused(until: BridgeFixture.now.addingTimeInterval(86_400))
    ) {
      try await fixture.bridge.serving(fixture.restic) { try await $0.backup(source) }
    }
  }

  @Test func commandsThatOnlyReadRunWhileUploadsArePaused() async throws {
    let fixture = try await BridgeFixture(dailyUploadLimit: 1_000_000)
    let source = try fixture.source()
    _ = try await fixture.bridge.serving(fixture.restic) { try await $0.createRepository() }
    try fixture.store.recordUpload(
      DriveUpload(at: BridgeFixture.now, bytes: 1_000_000), keeping: 86_400)

    // Each takes a lock, which still goes up.
    #expect(try await fixture.bridge.serving(fixture.restic) { try await $0.snapshots() }.isEmpty)
    await #expect(throws: BridgeFailure.self) {
      try await fixture.bridge.serving(fixture.restic) { try await $0.backup(source) }
    }
  }

  @Test func aRetriedChecksumMismatchIsntBlamedForALaterFailure() async throws {
    let fixture = try await BridgeFixture()
    let source = try fixture.source()
    _ = try await fixture.bridge.serving(fixture.restic) { try await $0.createRepository() }

    struct Unrelated: Error {}
    await #expect(throws: Unrelated.self) {
      try await fixture.bridge.serving(fixture.restic) { restic in
        await fixture.drive.failNextCall(with: .checksumMismatch(sent: "a", stored: "b"))
        // restic saves the file again, and the backup goes through.
        #expect(try await restic.backup(source).isComplete)
        throw Unrelated()
      }
    }
  }

  @Test func aStoppedCommandIsReportedAsStoppedNotAsDrivesFailure() async throws {
    let fixture = try await BridgeFixture(drive: InMemoryDrive(pageSize: 100, limitBytes: 100_000))
    let source = try fixture.source()
    _ = try await fixture.bridge.serving(fixture.restic) { try await $0.createRepository() }

    await #expect(throws: CancellationError.self) {
      try await fixture.bridge.serving(fixture.restic) { restic in
        _ = try? await restic.backup(source)
        throw CancellationError()
      }
    }
  }

  @Test func nothingIsLeftServingOnceTheCommandEnds() async throws {
    let fixture = try await BridgeFixture()
    let served = try await fixture.bridge.serving(fixture.restic) { $0 }
    #expect(served.restConnections == DriveBridge.connections)
    #expect(served.stuckRequestTimeout == .seconds(3600))
    let repository = served.repository
    #expect(repository.hasPrefix("rest:http+unix:///"))
    #expect(repository.hasSuffix("/restic.sock:/"))
    let socket = String(repository.dropFirst("rest:http+unix://".count).dropLast(":/".count))
    #expect(!FileManager.default.fileExists(atPath: socket))
    #expect(!FileManager.default.fileExists(atPath: (socket as NSString).deletingLastPathComponent))
  }
}
