import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// Each restic command Backup runs, killed outright (as a crash or a power cut would) early, midway
/// and late, leaves a repository that the next run completes and that `restic check` passes,
/// reading every byte.
///
/// One test at a time, and the longest run of the package: it takes no turn with the other suites
/// that run restic (`.runsRestic`), which would put it at the back of their queue.
@Suite(.serialized) struct BackupKillTests {
  @Test func aBackupKilledAtAnyStageIsCompletedByTheNextRun() async throws {
    // A backup's stages are what it has written, which the clock can't tell on a busy Mac: as it
    // opens the repository, after its first pack and after its second. (Of the six or so packs
    // this folder fills, the last few are written together at the end.)
    for stage in 0...2 {
      let fixture = try BackupFixture()
      let folderID = try Self.folderWithData(in: fixture)
      let repository = fixture.repositoryFolder
      let killer = Self.kill("backup", in: fixture) {
        ((try? Self.packs(in: repository)) ?? []).count >= stage
      }

      await #expect(throws: ResticFailure.self, "Killed after \(stage) packs") {
        try await fixture.run(folderID)
      }
      #expect(await killer.value, "The kill after \(stage) packs missed the backup")

      try await fixture.run(folderID)
      #expect(try await fixture.isHealthy(), "After the kill after \(stage) packs")
      #expect(
        try contents(of: try await fixture.restoredLatest(folderID))
          == contents(of: fixture.scratch.url.appendingPathComponent("docs")))
    }
  }

  @Test func aForgetKilledAtAnyStageIsCompletedByTheNextMaintenance() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    let file = try fixture.scratch.file("docs/a.txt")
    var version = 0
    func backUp(times: Int) async throws {
      for _ in 0..<times {
        version += 1
        try Data(count: version).write(to: file)
        try await fixture.run(folderID)
      }
    }
    // It keeps the latest 10, and one for each hour, day, week, month and year they fall in: how
    // many that is depends on the hour the test runs in, so it never counts them, only whether
    // the policy still has any to forget.
    // (15 by the first forget: five older than the latest 10, which one change of hour, day, week,
    // month or year can't all save.)
    try await backUp(times: 11)
    let today = Date()
    let snapshots = fixture.repositoryFolder.appendingPathComponent("snapshots")
    let repository = fixture.repositoryFolder

    // Removing a snapshot is a moment before restic exits, too short to land a kill in: the next
    // test leaves the state such a kill would.
    for (index, stage) in [Stage.starting, .locked].enumerated() {
      try await backUp(times: 4)
      let before = try Self.files(in: snapshots)
      let killer = Self.kill("forget", in: fixture) {
        switch stage {
        case .starting: true
        case .locked: !Self.heldLocks(in: repository).isEmpty
        case .changing: ((try? Self.files(in: snapshots)) ?? before).count < before.count
        }
      }
      // Forget runs once a day.
      let date = today.addingTimeInterval(Double(index + 1) * day)

      await #expect(throws: ResticFailure.self, "Killed \(stage)") {
        try await fixture.backup.maintain(now: date)
      }
      #expect(await killer.value, "The kill \(stage) missed the forget")

      // Counted from the repository's files, not asked of restic: the killed forget may have left
      // its lock, which the next maintenance clears and any other restic would stop at.
      let beforeMaintenance = try Self.files(in: snapshots).count
      try await fixture.backup.maintain(now: date)
      #expect(try await fixture.stillToForget(folderID).isEmpty, "After the kill \(stage)")
      try await backUp(times: 1)
      #expect(try await fixture.isHealthy(), "After the kill \(stage)")
      let kept = try await fixture.snapshots(folderID)
      // The maintenance removed some of the snapshots the cut-short forget left, and kept the
      // latest 10, the oldest and the new one at least.
      #expect(kept.count < beforeMaintenance + 1)
      #expect(kept.count >= 12)
      // No version points at a snapshot the cut-short forget removed.
      let versions = try fixture.store.backupVersions(folderID: folderID)
      #expect(Set(versions.map(\.snapshotID)).isSubset(of: Set(kept.map(\.id))))
    }
  }

  @Test func aForgetTheAppDidNotLiveToRecordIsReconciledByTheNext() async throws {
    let fixture = try BackupFixture()
    let folderID = try fixture.addWearing("docs")
    let file = try fixture.scratch.file("docs/a.txt")
    // 13, so that three are older than the latest 10 and a change of hour, day, week, month or
    // year between two of them, which saves two at most, still leaves one to forget.
    for count in 1...13 {
      try Data(count: count).write(to: file)
      if count == 2 { try fixture.scratch.file("docs/b.txt") }
      try await fixture.run(folderID)
    }
    let record = try fixture.record(folderID)
    // The forget ran to its end and the app was killed before it heard, with a lock left behind
    // as a restic killed at its last moment leaves one.
    let restic = try fixture.restic()
    let snapshotsBefore = try await fixture.snapshots(folderID).sorted { $0.time < $1.time }
    let groups = try await restic.forget(
      keeping: BackupBuff.policy(record.history), tags: [record.resticTag],
      host: try Machine.id())
    let keptByForget = Set(groups.flatMap(\.keep).map(\.id))
    let repository = fixture.repositoryFolder
    let killer = Self.kill("check", in: fixture) { !Self.heldLocks(in: repository).isEmpty }
    _ = try? await restic.check(wallClockLimit: hangLimit)
    #expect(await killer.value)

    try await fixture.backup.maintain()

    let kept = try await fixture.snapshots(folderID).sorted { $0.time < $1.time }
    // What the forget kept, however many that was.
    #expect(Set(kept.map(\.id)) == keptByForget)
    #expect(kept.count < snapshotsBefore.count)
    let versions = try fixture.store.backupVersions(folderID: folderID)
    #expect(Set(versions.map(\.snapshotID)).isSubset(of: Set(kept.map(\.id))))
    // b.txt was saved in the second backup: it is in that snapshot, or in the first one kept after.
    let holder = try #require(kept.first { $0.time >= snapshotsBefore[1].time })
    #expect(versions.filter { $0.path == "b.txt" }.map(\.snapshotID) == [holder.id])
    #expect(try await fixture.isHealthy())
  }

  @Test func aPruneKilledAtAnyStageIsCompletedByTheNextMaintenance() async throws {
    let fixture = try BackupFixture()
    let folderID = try Self.folderWithData(in: fixture)
    try await fixture.run(folderID)
    let repository = fixture.repositoryFolder

    for (index, stage) in Stage.all.enumerated() {
      // A folder whose backup goes with it, so the prune has packs to delete.
      let garbage = try fixture.addWearing("garbage-\(index)")
      try randomData(30_000_000).write(
        to: fixture.scratch.url.appendingPathComponent("garbage-\(index)/data.bin"))
      try await fixture.run(garbage)
      try fixture.backup.takeOff(folderID: garbage, isDeletingBackup: true)
      let indexes = fixture.repositoryFolder.appendingPathComponent("index")
      let before = try Self.files(in: indexes)
      let killer = Self.kill("prune", in: fixture) {
        switch stage {
        case .starting: true
        case .locked: !Self.heldLocks(in: repository).isEmpty
        case .changing: !((try? Self.files(in: indexes)) ?? before).isSubset(of: before)
        }
      }

      await #expect(throws: ResticFailure.self, "Killed \(stage)") {
        try await fixture.backup.maintain()
      }
      #expect(await killer.value, "The kill \(stage) missed the prune")

      try await fixture.backup.maintain()
      try await fixture.run(folderID)
      #expect(try await fixture.isHealthy(), "After the kill \(stage)")
      #expect(try fixture.store.pendingBackupDeletions().isEmpty)
      // The kept folder's snapshots, and none of the thrown-away ones'.
      #expect(try await fixture.restic().snapshots().count == index + 2)
    }
  }

  // MARK: - Helpers

  /// Where a forget or a prune is when it's killed, read from the repository's files: the clock
  /// can't tell on a busy Mac.
  private enum Stage: CustomStringConvertible {
    /// As restic opens the repository.
    case starting
    /// Once it holds the repository's lock.
    case locked
    /// Once it has changed the repository: a forget removed its first snapshot; a prune wrote its
    /// new index, before it deletes the old index and the packs nothing uses.
    case changing

    static let all: [Stage] = [.starting, .locked, .changing]

    var description: String {
      switch self {
      case .starting: "as it started"
      case .locked: "holding the lock"
      case .changing: "once it changed the repository"
      }
    }
  }

  /// A Backup folder with 40 files of random data, 80 MB in all: several packs' worth.
  private static func folderWithData(in fixture: BackupFixture) throws -> Int64 {
    let folderID = try fixture.addWearing("docs")
    for index in 0..<40 {
      try randomData(2_000_000).write(
        to: try fixture.scratch.file("docs/\(index % 4)/\(index).bin"))
    }
    return folderID
  }

  /// What `pgrep -f` finds the restic running `command` on the fixture's repository by. The
  /// scratch folder's name is unique, and no regular expression needs escaping in it.
  private static func pattern(_ command: String, in fixture: BackupFixture) -> String {
    "\(fixture.scratch.url.lastPathComponent)/repository .* \(command)( |$)"
  }

  /// Kills that restic with SIGKILL, as a crash or a power cut would, once `isDue` says so; true
  /// if it was still running then.
  private static func kill(
    _ command: String, in fixture: BackupFixture, when isDue: @escaping @Sendable () -> Bool
  ) -> Task<Bool, Never> {
    let pattern = pattern(command, in: fixture)
    return Task.detached {
      guard let processID = await processID(pattern, within: hangLimit) else { return false }
      while !isDue() {
        guard Darwin.kill(processID, 0) == 0 else { return false }
        try? await Task.sleep(for: .microseconds(500))
      }
      return Darwin.kill(processID, SIGKILL) == 0
    }
  }

  private static func processID(_ pattern: String, within limit: Duration) async -> pid_t? {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if let found = pgrep(pattern) { return found }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
  }

  /// The ID of the process `pgrep -f` finds by `pattern`, if any.
  private static func pgrep(_ pattern: String) -> pid_t? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", pattern]
    let output = Pipe()
    process.standardOutput = output
    do {
      try process.run()
    } catch {
      return nil
    }
    let printed = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: printed, as: UTF8.self).split(separator: "\n").first.flatMap {
      pid_t($0)
    }
  }

  /// The locks restic holds on the repository: each lock file once it is in place, not the
  /// temporary file restic writes it to first (`<id>-tmp-<n>`), which no other restic heeds.
  private static func heldLocks(in repository: URL) -> Set<String> {
    ((try? files(in: repository.appendingPathComponent("locks"))) ?? []).filter {
      !$0.contains("-tmp-")
    }
  }

  private static func files(in folder: URL) throws -> Set<String> {
    guard exists(folder) else { return [] }
    return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
  }

  /// The packs restic has finished writing: files named by their 64-digit ID in `data/`.
  private static func packs(in repository: URL) throws -> Set<String> {
    let data = repository.appendingPathComponent("data")
    return try files(in: data).reduce(into: []) { packs, shard in
      packs.formUnion(
        try files(in: data.appendingPathComponent(shard)).filter { $0.count == 64 })
    }
  }
}
