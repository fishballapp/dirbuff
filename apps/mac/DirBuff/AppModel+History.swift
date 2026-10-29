import AppKit
import DirBuffKit
import DirBuffUI
import Foundation
import os

private let logger = Logger(subsystem: "app.fishball.dirbuff", category: "history")

extension AppModel {
  /// Every run, with every folder DirBuff knows to name them. Nil if the database can't be read.
  func history(now: Date) async -> HistoryState? {
    let store = engine.store
    do {
      let runs = try await Task.detached { try store.runs() }.value
      return HistoryState(runs, folders: historyFolders(now: now), now: now)
    } catch {
      logger.error("Couldn't read History: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// A run's page; nil once the run is gone (trimmed, cleared, or its folders removed).
  func run(id: Int64, now: Date) async -> RunState? {
    let store = engine.store
    do {
      let (run, entries, inBin) = try await Task.detached {
        let entries = try store.journal(runID: id)
        // What the user emptied from the Bin, or took out themselves, is no longer where it went.
        let inBin = Set(
          entries.filter {
            $0.undoneAt == nil
              && $0.binnedPath.map { FileManager.default.fileExists(atPath: $0) } == true
          }
          .compactMap(\.id))
        return (try store.run(id: id), entries, inBin)
      }.value
      return run.map {
        RunState($0, entries: entries, folders: historyFolders(now: now), inBin: inBin, now: now)
      }
    } catch {
      logger.error("Couldn't read run \(id): \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Puts back what a run removed, with no confirmation: a file, a folder's all, or the
  /// notification's whole clean-up.
  func putBackFromHistory(entryIDs: [Int64]) async {
    await putBack(entryIDs: entryIDs)
    historyDidChange()
  }

  /// Forgets every finished run after asking. The run a clean-up is writing now stays, and shows
  /// once it finishes. What's in the Bin stays there.
  func clearHistoryAsking() {
    let alert = NSAlert()
    alert.messageText = "Clear History?"
    alert.informativeText =
      "All runs will be removed from History. Items in the \(SystemBin.name) stay there and can still be put back using Finder."
    alert.addButton(withTitle: "Clear History")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    // On the main actor, where a clean-up opens its run, so none can start between reading which
    // run is open and clearing the rest.
    do {
      try engine.store.clearHistory(keeping: openRunID)
    } catch {
      show(error, doing: "clear History")
    }
    historyDidChange()
  }

  /// Forgets the oldest runs once History passes its limit. Run after each clean-up.
  func trimHistory() async {
    let store = engine.store
    do {
      let trimmed = try await Task.detached { try store.trimHistory() }.value
      if trimmed > 0 { logger.info("Trimmed \(trimmed) runs from History") }
    } catch {
      logger.error("Couldn't trim History: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Tells open History pages to read it again.
  func historyDidChange() {
    historyRevision += 1
  }

  private func historyFolders(now: Date) -> [HistoryFolder] {
    HistoryFolder.all(reports, states: folders(now: now))
  }
}
