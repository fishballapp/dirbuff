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

    let first = try await restic.backup([source], tags: ["folder=docs"], host: "test-mac")
    #expect(first.isComplete)
    #expect(first.summary.filesNew == 2)
    #expect(first.unreadable.isEmpty)

    try Data("second".utf8).write(to: notes)
    let second = try await restic.backup([source], tags: ["folder=docs"], host: "test-mac")
    #expect(second.summary.filesChanged == 1)
    #expect(second.summary.filesUnmodified == 1)

    let snapshots = try await restic.snapshots(tags: ["folder=docs"], host: "test-mac")
    #expect(
      snapshots.map(\.id).sorted()
        == [first.summary.snapshotId, second.summary.snapshotId].compactMap { $0 }.sorted())
    #expect(snapshots.allSatisfy { $0.tags == ["folder=docs"] && $0.hostname == "test-mac" })
    #expect(snapshots.allSatisfy { abs($0.time.timeIntervalSinceNow) < 120 })
    #expect(snapshots.first?.paths == [source.path])

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
    // restic restores a path under the target as the path it was saved from.
    let copy = target.appendingPathComponent(notes.path)
    #expect(try String(contentsOf: copy, encoding: .utf8) == "second")
    #expect(
      try Data(contentsOf: target.appendingPathComponent(source.path + "/deep/er/photo.bin"))
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

    let result = try await restic.backup([source])

    #expect(!result.isComplete)
    #expect(result.unreadable.map(\.item) == [locked.path])
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
    _ = try await restic.backup([source])
    _ = try await restic.snapshots()
    try await restic.check(wallClockLimit: .seconds(60))

    // The repository, restic's cache and every file the runner could have made.
    #expect(try !scratch.contains(testPassword))
  }
}
