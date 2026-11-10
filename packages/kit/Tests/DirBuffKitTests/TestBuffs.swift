import DirBuffCore
import Foundation
import os

@testable import DirBuffKit

extension TemporaryBuff {
  /// Adds the folder at `url` and puts Temporary on it with `settings`; returns its id.
  func addWearing(_ url: URL, _ settings: TemporarySettings = TemporarySettings()) throws -> Int64 {
    let id = try require(engine.add(url).id)
    try putOn(folderID: id)
    try save(settings, folderID: id)
    return id
  }

  /// The folder's wear, which the test expects it to have.
  func requireWear(_ folderID: Int64) throws -> Wear<TemporarySettings> {
    try require(wear(folderID: folderID))
  }

  func read(folderID: Int64, now: Date = Date()) throws -> TemporaryStatus {
    try read(engine.locate(folderID: folderID), requireWear(folderID), now: now)
  }

  /// Runs the folder as a clean-up would.
  @discardableResult
  func run(folderID: Int64, now: Date, runID: Int64? = nil) throws -> RunSummary {
    try runHearingProgress(folderID: folderID, now: now, runID: runID).summary
  }

  /// Runs the folder as a clean-up would, and returns what it heard of its progress too.
  func runHearingProgress(folderID: Int64, now: Date, runID: Int64? = nil) throws
    -> (summary: RunSummary, progress: [RunProgress])
  {
    let heard = OSAllocatedUnfairLock<[RunProgress]>(initialState: [])
    let summary = try run(
      engine.locate(folderID: folderID), requireWear(folderID),
      context: RunContext(runID: runID, scheduledAt: now) { progress in
        heard.withLock { $0.append(progress) }
      })
    return (summary, heard.withLock { $0 })
  }
}
