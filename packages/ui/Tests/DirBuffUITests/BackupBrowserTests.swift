import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private let day: TimeInterval = 86_400

private func kept(_ id: String, daysAgo: Double) -> KeptBackup {
  KeptBackup(id: id, savedAt: now.addingTimeInterval(-daysAgo * day))
}

/// Newest first, as the page lists them.
private let backups = [
  kept("new", daysAgo: 0.01), kept("mid", daysAgo: 3), kept("old", daysAgo: 20),
]

private func file(_ path: String, _ sinceThen: BackupItem.SinceThen? = nil, size: Int64 = 100)
  -> BackupItem
{
  BackupItem(path: path, kind: .file, size: size, sinceThen: sinceThen)
}

private func folder(_ path: String, _ sinceThen: BackupItem.SinceThen? = nil) -> BackupItem {
  BackupItem(path: path, kind: .folder, sinceThen: sinceThen)
}

private func place(_ backup: String, _ path: String) -> BackupPlace {
  BackupPlace(backupID: backup, path: path)
}

/// Documents, three backups, its top listed in the newest.
private func opened() -> BackupBrowserState {
  var state = BackupBrowserState(
    folderName: "Documents", folderPath: "\(home)/Documents", backups: .loaded(backups))
  state.didList(place("new", ""), [folder("Finance"), file("notes.txt")])
  return state
}

@Suite struct BackupBrowserSelectionTests {
  @Test func itOpensOnTheNewestBackupAtItsTopWithNothingSelected() {
    let state = opened()

    #expect(state.backupID == "new")
    #expect(state.selection == nil)
    #expect(state.columns.map(\.place) == [place("new", "")])
    #expect(state.listingsWanted.isEmpty)
  }

  @Test func whileTheBackupsLoadThereAreNoColumns() {
    let state = BackupBrowserState(folderName: "Documents", folderPath: "\(home)/Documents")

    #expect(state.columns.isEmpty)
    #expect(state.backup == nil)
  }

  @Test func aFolderSelectedOpensTheNextColumnWhichAsksForItsListing() {
    var state = opened()

    state.select(folder("Finance"))

    #expect(state.columns.map(\.place.path) == ["", "Finance"])
    #expect(state.listingsWanted == [place("new", "Finance")])
    #expect(state.columns[0].selectedPath == "Finance")
    #expect(state.columns[0].isActive)
    #expect(state.columns[1].listing == .loading)
  }

  @Test func aFileDeepDownShowsEveryFolderOnTheWayWithOnlyItsOwnColumnActive() {
    var state = opened()
    state.didList(place("new", "Finance"), [folder("Finance/2026")])
    state.didList(place("new", "Finance/2026"), [file("Finance/2026/Lease.pdf")])

    state.select(file("Finance/2026/Lease.pdf"))

    #expect(state.columns.map(\.place.path) == ["", "Finance", "Finance/2026"])
    #expect(
      state.columns.map(\.selectedPath) == ["Finance", "Finance/2026", "Finance/2026/Lease.pdf"])
    #expect(state.columns.map(\.isActive) == [false, false, true])
    #expect(state.selectedItem == file("Finance/2026/Lease.pdf"))
  }

  @Test func noColumnOpensPastOneThatIsntListed() {
    var state = opened()
    state.select(file("Finance/2026/Lease.pdf"))

    #expect(state.columns.map(\.place.path) == ["", "Finance"])
    #expect(state.listingsWanted == [place("new", "Finance")])
  }

  @Test func anotherBackupStartsAtItsTop() {
    var state = opened()
    state.select(file("notes.txt"))

    state.selectBackup("old")

    #expect(state.selection == nil)
    #expect(state.listingsWanted == [place("old", "")])
  }

  @Test func aBackupNoLongerKeptGivesWayToTheNewest() {
    var state = opened()
    state.selectBackup("old")

    state.show(.loaded(Array(backups.prefix(2))))

    #expect(state.backupID == "new")
  }

  @Test func aTimelineEntryShowsItsBackupWithTheSameFile() throws {
    var state = opened()
    state.select(file("notes.txt"))
    state.histories["notes.txt"] = FileHistory(
      path: "notes.txt",
      versions: [
        BackupVersion(
          path: "notes.txt", snapshotID: "old", savedAt: backups[2].savedAt, change: .added,
          size: 10),
        BackupVersion(
          path: "notes.txt", snapshotID: "mid", savedAt: backups[1].savedAt, change: .changed,
          size: 20),
      ])
    let entry = try #require(state.timeline(now: now, calendar: calendar)?.entries.last)

    state.show(entry)

    #expect(state.backupID == "old")
    #expect(state.selection?.path == "notes.txt")
    #expect(state.listingsWanted == [place("old", "")])
  }

  @Test func aSelectionTheBackupDoesntHoldStopsAtTheFolderThatLacksIt() {
    var state = opened()
    state.didList(place("new", "Finance"), [file("Finance/a.txt")])
    state.select(file("Finance/a.txt"))
    state.selectBackup("old")
    state.select(file("Finance/a.txt"))

    state.didList(place("old", ""), [folder("Finance")])
    state.didList(place("old", "Finance"), [file("Finance/b.txt")])

    #expect(state.selection?.path == "Finance")
  }

  @Test func theArrowKeysMoveAsFindersDo() {
    var state = opened()
    state.didList(place("new", "Finance"), [file("Finance/a.txt"), file("Finance/b.txt")])

    state.move(.down)
    #expect(state.selection?.path == "Finance")
    state.move(.right)
    #expect(state.selection?.path == "Finance/a.txt")
    state.move(.down)
    #expect(state.selection?.path == "Finance/b.txt")
    state.move(.down)
    #expect(state.selection?.path == "Finance/b.txt")
    state.move(.left)
    #expect(state.selection?.path == "Finance")
    state.move(.left)
    #expect(state.selection == nil)
  }
}

@Suite struct BackupBrowserWordsTests {
  @Test func theMarksAreWordsOfTheirOwn() {
    let state = opened()

    #expect(state.sinceThen(of: file("notes.txt")) == nil)
    #expect(
      state.sinceThen(of: file("Finance/a.txt", .deleted))
        == "Finance on this Mac doesn't have it any more.")
    #expect(
      state.sinceThen(of: file("notes.txt", .changed))
        == "It has changed on this Mac since this backup.")
    #expect(state.sinceThen(of: folder("Finance", .changed))?.hasPrefix("Something in it") == true)
  }

  @Test func aFolderThatIsntOnThisMacAsksWhereToRestore() {
    var state = opened()
    state.isFolderAway = true
    let item = file("notes.txt", .unknown)

    #expect(state.restoreTitle == "Restore To…")
    #expect(state.sinceThen(of: item)?.hasPrefix("Documents isn't on this Mac now") == true)
    #expect(state.restoreSentence(for: item).contains("Restore To… asks where"))
    #expect(state.restoreFolderSentence.contains("Restore Folder… asks where"))
  }

  @Test func aFolderThatCantBeReadPromisesNeitherPlace() {
    let state = opened()
    let item = file("Finance/a.txt", .unknown)

    #expect(state.sinceThen(of: item)?.contains("can't read Finance") == true)
    #expect(state.restoreSentence(for: item).contains("under its own name if that's free"))
  }

  @Test func eachColumnIsToldOnlyWhichOfItsItemsAreRestoring() {
    var state = opened()
    state.restores[place("new", "notes.txt")] = .restoring(
      RestoreRun(folderName: "notes.txt", path: "\(home)/Documents/notes.txt"))
    state.restores[place("new", "Finance")] = .done(path: "\(home)/Documents/Finance")
    state.restores[place("old", "notes.txt")] = .restoring(
      RestoreRun(folderName: "notes.txt", path: "\(home)/Documents/notes.txt"))

    #expect(state.restoringPaths(in: "new") == ["notes.txt"])
    #expect(state.restoringPaths(in: "mid").isEmpty)
  }

  @Test func restoreSaysWhereItGoesAndThatNothingIsReplaced() {
    let state = opened()

    #expect(
      state.restoreSentence(for: file("notes.txt", .deleted))
        == "Restore puts it back in Documents, as this backup saved it.")
    let beside = state.restoreSentence(for: file("notes.txt", .changed))
    #expect(
      beside.contains(BackupBuff.datedName(of: file("notes.txt"), savedAt: backups[0].savedAt)))
    #expect(beside.hasSuffix("Nothing is replaced."))
  }

  @Test func quickLookTakesFilesUpToItsLimit() {
    let state = opened()
    let limit = BackupBrowserState.quickLookLimit

    #expect(state.canQuickLook(file("a.pdf", size: limit)))
    #expect(!state.canQuickLook(file("a.mov", size: limit + 1)))
    #expect(
      state.quickLookRefusal(for: file("a.mov", size: limit + 1))?.contains("Restore it") == true)
    #expect(!state.canQuickLook(folder("Finance")))
  }

  @Test func aFolderCountsWhatItHoldsOnceListed() {
    var state = opened()
    #expect(state.facts(of: folder("Finance")) == "Folder")

    state.didList(place("new", "Finance"), [file("Finance/a.txt"), file("Finance/b.txt")])

    #expect(state.facts(of: folder("Finance")) == "Folder · 2 items")
  }

  @Test func aRestoreBelongsToItsItemNotToTheSelection() {
    var state = opened()
    state.select(file("notes.txt"))
    state.restores[place("new", "notes.txt")] = .restoring(
      RestoreRun(folderName: "notes.txt", path: "\(home)/Documents/notes.txt"))

    #expect(state.selectedRestore != nil)
    state.select(folder("Finance"))
    #expect(state.selectedRestore == nil)
    state.selectBackup("old")
    state.select(file("notes.txt"))
    #expect(state.selectedRestore == nil)
  }

  @Test func whatTheWorkWaitsBehindIsSaid() {
    var state = opened()
    #expect(state.listingSentence == "Asking Google Drive…")
    #expect(state.dragSentence == nil)

    state.busyWith = .backup
    state.dragsInFlight = 2

    #expect(state.listingSentence == "Waiting for the backup that's running to finish.")
    #expect(
      state.dragSentence
        == "Copying 2 items to Finder. Waiting for the backup that's running to finish.")
    #expect(BackupBusy.check.waitingSentence.contains("weekly check"))
  }

  @Test func whereARestoreWentIsSaid() {
    let state = opened()

    #expect(
      state.restoredSentence(path: "\(home)/Documents/Finance/a.txt")
        == "It is back in Finance as “a.txt”.")
    #expect(
      state.restoredSentence(path: "\(home)/Documents/notes.txt")
        == "It is back in Documents as “notes.txt”.")
  }
}

@Suite struct FileTimelineTests {
  /// The page showing `backup`, with `history` selected; this Mac has followed the folder since
  /// `trackedSince`, its first backup unless a test says otherwise.
  private func state(
    _ history: FileHistory, showing backup: String = "new",
    trackedSince: Date? = backups[2].savedAt
  ) -> BackupBrowserState {
    var history = history
    history.trackedSince = trackedSince
    var state = opened()
    state.selectBackup(backup)
    state.select(file(history.path))
    state.histories[history.path] = history
    return state
  }

  private func version(_ backup: Int, _ change: BackupVersion.Change, replacedBy: Int? = nil)
    -> BackupVersion
  {
    BackupVersion(
      path: "notes.txt", snapshotID: backups[backup].id, savedAt: backups[backup].savedAt,
      change: change, size: change == .removed ? nil : 100,
      replacedAt: replacedBy.map { backups[$0].savedAt })
  }

  @Test func aFileThatNeverChangedIsOneSentence() throws {
    let timeline = try #require(
      state(FileHistory(path: "notes.txt", versions: [])).timeline(now: now, calendar: calendar))

    #expect(timeline.entries.isEmpty)
    #expect(
      timeline.sentence
        == "Unchanged since the first backup on \(versionDay(backups[2].savedAt, now: now, calendar: calendar))."
    )
  }

  @Test func theVersionTheBackupShownHoldsIsTheCurrentOne() throws {
    let history = FileHistory(
      path: "notes.txt", versions: [version(2, .changed, replacedBy: 1), version(1, .changed)])

    let newest = try #require(state(history).timeline(now: now, calendar: calendar))
    let oldest = try #require(state(history, showing: "old").timeline(now: now, calendar: calendar))

    #expect(newest.entries.map(\.isCurrent) == [true, false])
    #expect(oldest.entries.map(\.isCurrent) == [false, true])
    #expect(
      newest.entries.map(\.detail) == [
        "Changed · \(bytes(100))",
        "As backed up before \(versionDay(backups[1].savedAt, now: now, calendar: calendar))",
      ])
    #expect(newest.sentence == nil)
  }

  @Test func aDeletionCantBeShownNorABackupNoLongerKept() throws {
    var history = FileHistory(
      path: "notes.txt", versions: [version(2, .added), version(1, .removed)])
    history.versions.insert(
      BackupVersion(
        path: "notes.txt", snapshotID: "forgotten", savedAt: now.addingTimeInterval(-30 * day),
        change: .added, size: 1), at: 0)

    let timeline = try #require(state(history).timeline(now: now, calendar: calendar))

    #expect(timeline.entries.map(\.canShow) == [false, true, false])
    #expect(timeline.entries.first?.detail == "Deleted")
  }

  @Test func anEarlierVersionThinnedAwayOrNotYetKnownIsSaid() throws {
    let thinned = FileHistory(
      path: "notes.txt", versions: [version(1, .changed)], hasEarlierVersionNotKept: true)
    let unknown = FileHistory(
      path: "notes.txt", versions: [version(1, .changed)], earlierVersionIsUnknown: true)

    #expect(
      state(thinned).timeline(now: now, calendar: calendar)?.sentence
        == FileTimeline.earlierNotKept)
    #expect(
      state(unknown).timeline(now: now, calendar: calendar)?.sentence?.contains("still checking")
        == true)
  }

  @Test func backupsFromBeforeThisMacFollowedTheFolderAreNotVouchedFor() throws {
    let unchanged = FileHistory(path: "notes.txt", versions: [])
    let day = versionDay(backups[1].savedAt, now: now, calendar: calendar)

    let partly = try #require(
      state(unchanged, trackedSince: backups[1].savedAt).timeline(now: now, calendar: calendar))
    #expect(
      partly.sentence
        == "Unchanged since \(day). Backups from before \(day) may hold other versions: choose one to look."
    )
    let changed = FileHistory(path: "notes.txt", versions: [version(0, .changed)])
    #expect(
      state(changed, trackedSince: backups[1].savedAt).timeline(now: now, calendar: calendar)?
        .sentence == "Backups from before \(day) may hold other versions: choose one to look.")
  }

  @Test func neverTwoSentencesAboutWhatIsntListed() throws {
    let thinned = FileHistory(
      path: "notes.txt", versions: [version(0, .changed)], hasEarlierVersionNotKept: true)
    let day = versionDay(backups[1].savedAt, now: now, calendar: calendar)

    let sentence = state(thinned, trackedSince: backups[1].savedAt)
      .timeline(now: now, calendar: calendar)?.sentence

    #expect(sentence == "Backups from before \(day) may hold other versions: choose one to look.")
  }

  @Test func aBackupFromBeforeTheTrackingPointVouchesForNothing() throws {
    let unchanged = FileHistory(path: "notes.txt", versions: [])
    let day = versionDay(backups[1].savedAt, now: now, calendar: calendar)

    let sentence = state(unchanged, showing: "old", trackedSince: backups[1].savedAt)
      .timeline(now: now, calendar: calendar)?.sentence

    #expect(sentence?.hasPrefix("Its versions are known only from \(day) on") == true)
    #expect(sentence?.contains("Unchanged") == false)
  }

  @Test func aBackupTakenOverAndNotYetBackedUpHereClaimsNothing() throws {
    let unchanged = FileHistory(path: "notes.txt", versions: [])

    for since in [nil, now] {
      let timeline = try #require(
        state(unchanged, trackedSince: since).timeline(now: now, calendar: calendar))
      #expect(timeline.sentence?.hasPrefix("Which backups hold other versions isn't known") == true)
      #expect(timeline.sentence?.contains("Unchanged") == false)
    }
  }

  @Test func aFolderHasNoTimeline() {
    var state = opened()
    state.select(folder("Finance"))

    #expect(state.timeline(now: now, calendar: calendar) == nil)
  }

  @Test func aBackupSavedTodayIsToldWithItsTimeAndAnOldOneWithItsYear() {
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    let today = now.addingTimeInterval(-60)
    let lastYear = now.addingTimeInterval(-400 * day)

    #expect(
      versionMoment(today, now: now, calendar: calendar)
        == "Today, \(today.formatted(style.hour().minute()))")
    #expect(
      versionMoment(lastYear, now: now, calendar: calendar).hasPrefix(
        lastYear.formatted(style.day().month(.abbreviated).year())))
  }
}
