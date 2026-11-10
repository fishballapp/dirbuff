import Foundation
import Testing

@testable import DirBuffKit

/// The real restic, bundled with the app, against a repository in a temporary folder.
@Suite struct ResticTests {
  @Test func aRepositoryLivesFromInitToRestore() async throws {
    let scratch = try Scratch()
    let restic = try testRestic(in: scratch)
    let source = try scratch.folder("source")
    let notes = try scratch.file("source/notes.txt")
    try Data("first".utf8).write(to: notes)
    try scratch.file("source/deep/er/photo.bin", bytes: 5_000)

    let repositoryID = try await restic.createRepository()
    #expect(repositoryID.count == 64)

    let first = try await restic.backup(source, tags: ["folder=docs"], host: "test-mac")
    #expect(first.isComplete)
    #expect(first.summary.filesNew == 2)
    #expect(first.unreadable.isEmpty)

    try Data("second".utf8).write(to: notes)
    let second = try await restic.backup(source, tags: ["folder=docs"], host: "test-mac")
    #expect(second.summary.filesChanged == 1)
    #expect(second.summary.filesUnmodified == 1)

    let snapshots = try await restic.snapshots(tags: ["folder=docs"], host: "test-mac")
    #expect(
      snapshots.map(\.id).sorted()
        == [first.summary.snapshotId, second.summary.snapshotId].compactMap { $0 }.sorted())
    #expect(snapshots.allSatisfy { $0.tags == ["folder=docs"] && $0.hostname == "test-mac" })
    #expect(snapshots.allSatisfy { abs($0.time.timeIntervalSinceNow) < 120 })
    #expect(snapshots.first?.paths == [source.path])

    let changes = try await restic.diff(
      from: try #require(first.summary.snapshotId), to: try #require(second.summary.snapshotId))
    #expect(changes == [DiffChange(path: "/notes.txt", modifier: .modified)])

    let groups = try await restic.forget(
      keeping: ForgetPolicy(last: 1), tags: ["folder=docs"], host: "test-mac")
    #expect(groups.flatMap(\.remove).map(\.id) == [first.summary.snapshotId].compactMap { $0 })
    #expect(groups.flatMap(\.keep).map(\.id) == [second.summary.snapshotId].compactMap { $0 })
    #expect(try await restic.snapshots().count == 1)

    try await restic.prune(wallClockLimit: .seconds(60))
    let checked = try await restic.check(readDataSubset: "100%", wallClockLimit: .seconds(60))
    #expect(checked.isHealthy)

    let target = try scratch.folder("restored")
    let restored = try await restic.restore(
      snapshot: second.summary.snapshotId ?? "latest", to: target)
    // Its count includes the folders.
    #expect(restored.filesRestored >= 2)
    // The folder is the snapshot's root, so its contents land straight in the target.
    let copy = target.appendingPathComponent("notes.txt")
    #expect(try String(contentsOf: copy, encoding: .utf8) == "second")
    #expect(
      try Data(contentsOf: target.appendingPathComponent("deep/er/photo.bin"))
        == Data(count: 5_000))
  }

  @Test func theFilesBackupCouldNotReadAreNamedAndTheRestIsSaved() async throws {
    let scratch = try Scratch()
    let restic = try testRestic(in: scratch)
    let source = try scratch.folder("source")
    try scratch.file("source/readable.txt")
    let locked = try scratch.file("source/locked.txt")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
    }
    try #require(!FileManager.default.isReadableFile(atPath: locked.path), "Running as root")
    _ = try await restic.createRepository()

    let result = try await restic.backup(source)

    #expect(!result.isComplete)
    #expect(result.unreadable.count == 1)
    #expect(result.unreadable.first?.item.hasSuffix("locked.txt") == true)
    #expect(result.summary.filesNew == 1)
    #expect(try await restic.snapshots().count == 1)
  }

  @Test func theWrongPasswordIsNamed() async throws {
    let scratch = try Scratch()
    _ = try await testRestic(in: scratch).createRepository()

    let wrong = try testRestic(in: scratch, password: "not the password")

    await #expect {
      try await wrong.snapshots()
    } throws: { error in
      guard case ResticFailure.exited(.wrongPassword, let message) = error else { return false }
      return message.contains("wrong password")
    }
  }

  @Test func aRepositoryThatIsNotThereIsNamed() async throws {
    let scratch = try Scratch()
    let restic = try testRestic(in: scratch)

    await #expect {
      try await restic.snapshots()
    } throws: { error in
      guard case ResticFailure.exited(.repositoryMissing, _) = error else { return false }
      return true
    }
  }

  @Test func theRepositoryPasswordIsNeverOnDisk() async throws {
    let scratch = try Scratch()
    let restic = try testRestic(in: scratch)
    let source = try scratch.folder("source")
    try scratch.file("source/a.txt", bytes: 100)
    _ = try await restic.createRepository()
    _ = try await restic.backup(source)
    _ = try await restic.snapshots()
    try await restic.check(wallClockLimit: .seconds(60))

    // The repository, restic's cache and every file the runner could have made.
    #expect(try !scratch.contains(testPassword))
  }

  @Test func excludedPatternsAndCachesAreLeftOut() async throws {
    let scratch = try Scratch()
    let restic = try testRestic(in: scratch)
    let source = try scratch.folder("source")
    try scratch.file("source/kept.txt")
    try scratch.file("source/a/node_modules/dep.js")
    try scratch.file("source/odd*name$HOME/x")
    try scratch.file("source/cache/data")
    try Data(
      "Signature: 8a477f597d28d172789f06886806bc55\n".utf8
    ).write(to: source.appendingPathComponent("cache/CACHEDIR.TAG"))
    _ = try await restic.createRepository()

    _ = try await restic.backup(
      source, excluding: ["node_modules", Exclusions.escaped(source.path + "/odd*name$HOME")],
      excludingCaches: true)

    let target = try scratch.folder("restored")
    _ = try await restic.restore(snapshot: "latest", to: target)
    #expect(exists(target.appendingPathComponent("kept.txt")))
    #expect(exists(target.appendingPathComponent("a")))
    #expect(!exists(target.appendingPathComponent("a/node_modules")))
    #expect(!exists(target.appendingPathComponent("odd*name$HOME")))
    // restic keeps a cache folder and its tag, and leaves out the rest.
    #expect(!exists(target.appendingPathComponent("cache/data")))
  }

  @Test func aKeyIsAddedAndTheOldOneRemoved() async throws {
    let scratch = try Scratch()
    let old = try testRestic(in: scratch)
    _ = try await old.createRepository()
    let oldKey = try #require(try await old.keys().first)
    #expect(oldKey.isCurrent)

    let addedID = try await old.addKey(newPassword: "a new password")

    let new = try testRestic(in: scratch, password: "a new password")
    let keys = try await new.keys()
    #expect(Set(keys.map(\.id)) == [oldKey.id, addedID])
    #expect(keys.first { $0.isCurrent }?.id == addedID)
    try await new.removeKey(id: oldKey.id)
    #expect(try await new.keys().map(\.id) == [addedID])
    await #expect {
      try await old.snapshots()
    } throws: { error in
      guard case ResticFailure.exited(.wrongPassword, _) = error else { return false }
      return true
    }
    #expect(try !scratch.contains("a new password"))
  }

  @Test func snapshotsAreForgottenByID() async throws {
    let scratch = try Scratch()
    let restic = try testRestic(in: scratch)
    let source = try scratch.folder("source")
    try scratch.file("source/a.txt")
    _ = try await restic.createRepository()
    let first = try await restic.backup(source, tags: ["folder=a"])
    _ = try await restic.backup(source, tags: ["folder=b"])

    try await restic.forget(snapshotIDs: [try #require(first.summary.snapshotId)])

    #expect(try await restic.snapshots().flatMap(\.tags) == ["folder=b"])
  }

  @Test func forgettingWhereNoSnapshotMatchesFindsNothing() async throws {
    let scratch = try Scratch()
    let restic = try testRestic(in: scratch)
    _ = try await restic.createRepository()

    // restic prints nothing at all here.
    #expect(try await restic.forget(keeping: ForgetPolicy(last: 1), tags: ["folder=none"]) == [])
  }

  @Test func aPolicyKeepsWithinSpansAndForEver() {
    let policy = ForgetPolicy(
      last: 10, yearly: .unlimited, withinHourly: .hours(48), withinMonthly: .months(24),
      withinYearly: Span(years: 1, months: 2))
    #expect(
      policy.arguments == [
        "--keep-last", "10", "--keep-yearly", "unlimited", "--keep-within-hourly", "48h",
        "--keep-within-monthly", "24m", "--keep-within-yearly", "1y2m",
      ])
  }
}

private typealias Span = ForgetPolicy.Span
