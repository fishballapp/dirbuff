import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// Times a backup of a big folder, then a run with nothing changed, as the app runs them (at
/// utility priority, on two cores). Only with DIRBUFF_MEASURE_BACKUP=<folder>; the repository goes
/// in a temporary folder.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DIRBUFF_MEASURE_BACKUP"] != nil))
struct BackupMeasureTests {
  @Test func aBigFolderAndThenNoChange() async throws {
    let folder = URL(
      fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DIRBUFF_MEASURE_BACKUP"]))
    let scratch = try Scratch()
    let engine = Engine(store: try Store.inMemory())
    let backup = BackupBuff(
      engine: engine,
      storage: LocalRepository(folder: scratch.url.appendingPathComponent("repository")),
      keychain: TestKeychain(), executable: try resticExecutable(),
      cacheDirectory: scratch.url.appendingPathComponent("cache"), home: scratch.url)
    let folderID = try require(engine.add(folder).id)
    try backup.putOn(folderID: folderID)

    let walk = try await Self.time {
      _ = Exclusions.scan(try canonicalPath(of: folder), leftOut: [], home: "/nowhere", own: [])
    }
    print("measure: the leave-out walk alone took \(walk)")
    for name in ["first backup", "no change"] {
      var summary: RunSummary?
      let took = try await Self.time {
        summary = try await backup.run(
          engine.locate(folderID: folderID), require(backup.wear(folderID: folderID)),
          context: RunContext(runID: nil, scheduledAt: Date()))
      }
      print("measure: \(name) took \(took): \(String(describing: summary))")
      print("measure: load \(Self.loadAverage())")
    }
  }

  private static func time(_ body: () async throws -> Void) async throws -> Duration {
    let started = ContinuousClock.now
    try await body()
    return ContinuousClock.now - started
  }

  private static func loadAverage() -> String {
    var loads = [Double](repeating: 0, count: 3)
    _ = getloadavg(&loads, 3)
    return loads.map { String(format: "%.1f", $0) }.joined(separator: " ")
  }
}
