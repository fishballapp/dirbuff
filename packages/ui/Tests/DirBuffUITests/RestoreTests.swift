import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func version(
  _ path: String, _ secondsAgo: TimeInterval, _ change: BackupVersion.Change, _ size: Int64? = 100
) -> BackupVersion {
  BackupVersion(
    path: path, snapshotID: "s\(Int(secondsAgo))", savedAt: now.addingTimeInterval(-secondsAgo),
    change: change, size: change == .removed ? nil : size)
}

private let day: TimeInterval = 86_400

private func versions(_ list: [BackupVersion], notKept: Set<String> = []) -> VersionsState {
  VersionsState(
    folderID: 1, folderName: "Documents", folderPath: "\(home)/Documents",
    histories: Dictionary(grouping: list, by: \.path).map { path, versions in
      FileHistory(
        path: path, versions: versions.sorted { $0.savedAt < $1.savedAt },
        hasEarlierVersionNotKept: notKept.contains(path))
    }, now: now, calendar: calendar)
}

private func snapshot(_ id: String, secondsAgo: TimeInterval, bytes: Int64? = nil) throws
  -> ResticSnapshot
{
  let time = ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
  let summary = bytes.map { #","summary":{"total_bytes_processed":\#($0)}"# } ?? ""
  let json =
    #"{"id":"\#(id)","short_id":"\#(id)","time":"\#(time)","hostname":"mac","paths":["/x/Documents"],"tags":[]\#(summary)}"#
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(ResticSnapshot.self, from: Data(json.utf8))
}

@Suite struct VersionsStateTests {
  @Test func filesAreGroupedByPathNewestChangeFirst() {
    let state = versions([
      version("a.txt", 3 * day, .added), version("b.txt", day, .added),
      version("a.txt", 2 * day, .changed),
    ])

    #expect(state.files.map(\.path) == ["b.txt", "a.txt"])
    #expect(state.files[1].versions.map(\.change) == [.changed, .added])
  }

  @Test func aFileWhoseLastVersionIsADeletionIsDeleted() {
    let state = versions([
      version("gone.txt", 3 * day, .added), version("gone.txt", day, .removed),
      version("here.txt", day, .changed),
    ])

    #expect(state.files(.onThisMac, matching: "").map(\.path) == ["here.txt"])
    #expect(state.files(.deleted, matching: "").map(\.path) == ["gone.txt"])
    #expect(state.count(.deleted) == 1)
  }

  @Test func aDeletionHoldsNothingToRestore() throws {
    let state = versions([version("gone.txt", 3 * day, .added), version("gone.txt", day, .removed)])
    let file = try #require(state.files.first)

    #expect(file.versions.map(\.canRestore) == [false, true])
    #expect(file.restorableCount == 1)
    #expect(file.versionCount == "1 version")
    #expect(file.versions.first?.detail == "Deleted")
    #expect(file.size == bytes(100))
  }

  @Test func theNewestVersionIsTheLatestBackup() throws {
    let state = versions([version("a.txt", 3 * day, .added), version("a.txt", day, .changed)])
    let file = try #require(state.files.first)

    #expect(
      file.versions.map(\.detail) == ["Latest backup · \(bytes(100))", "Added · \(bytes(100))"])
  }

  @Test func theVersionBeforeTheFirstChangeSaysWhatItIs() throws {
    let before = BackupVersion(
      path: "a.txt", snapshotID: "before", savedAt: now.addingTimeInterval(-9 * day),
      change: .changed, size: nil, replacedAt: now.addingTimeInterval(-3 * day))
    let state = versions([before, version("a.txt", 3 * day, .changed)])
    let file = try #require(state.files.first)
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    let replaced = now.addingTimeInterval(-3 * day)

    #expect(file.versions.map(\.canRestore) == [true, true])
    #expect(file.versionCount == "2 versions")
    #expect(
      file.versions[1].detail
        == "As backed up before \(replaced.formatted(style.day().month(.abbreviated)))")
    #expect(file.hasEarlierVersionNotKept == false)
  }

  @Test func aFileWhoseEarlierVersionWasThinnedAwaySaysSo() throws {
    let state = versions([version("a.txt", day, .changed)], notKept: ["a.txt"])
    let file = try #require(state.files.first)

    #expect(file.hasEarlierVersionNotKept)
    #expect(file.versionCount == "1 version")
    #expect(VersionedFile.earlierNotKept.hasPrefix("No earlier version is kept"))
  }

  @Test func theSearchMatchesNameAndFolder() {
    let state = versions([
      version("Finance/Receipts.xlsx", day, .changed), version("Lease.pdf", day, .changed),
    ])

    #expect(state.files(.onThisMac, matching: "receipts").map(\.name) == ["Receipts.xlsx"])
    #expect(state.files(.onThisMac, matching: "finance").map(\.name) == ["Receipts.xlsx"])
    #expect(state.files(.onThisMac, matching: "").count == 2)
    #expect(state.files.first { $0.name == "Receipts.xlsx" }?.parent == "Finance")
  }

  @Test func eachEmptyListSaysWhy() {
    let none = versions([])
    let onlyDeleted = versions([version("x", day, .removed)])

    #expect(none.emptiness(.onThisMac, query: "").title.contains("No file has changed"))
    #expect(
      none.emptiness(.onThisMac, query: "").detail.contains("earlier versions are listed here"))
    #expect(none.emptiness(.onThisMac, query: "x").title == "No matches")
    #expect(onlyDeleted.emptiness(.onThisMac, query: "").title.contains("deleted"))
    #expect(
      versions([version("a", day, .changed)]).emptiness(.deleted, query: "").title
        == "No file has been deleted")
    #expect(none.subtitle == "Backup · no file has changed yet")
    #expect(versions([version("a", day, .changed)]).subtitle == "Backup · 1 file with versions")
  }

  @Test func aVersionSavedTodayIsToldWithItsTimeAndAnOldOneWithItsYear() {
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
    let recent = now.addingTimeInterval(-60)
    let old = now.addingTimeInterval(-800 * day)

    #expect(
      versionMoment(recent, now: now, calendar: calendar)
        == "Today, \(recent.formatted(style.hour().minute()))")
    #expect(
      versionMoment(old, now: now, calendar: calendar)
        == "\(old.formatted(style.day().month(.abbreviated).year())), \(old.formatted(style.hour().minute()))"
    )
  }
}

@Suite struct RestoreProblemTests {
  private func problem(_ error: any Error, _ subject: RestoreProblem.Subject = .backup)
    -> RestoreProblem
  {
    RestoreProblem(error, while: subject)
  }

  @Test func theWordsAreBackupErrorWordsWithWhatToDoAndThatNothingChanged() {
    let error = BackupBuff.Failure.outsideFolder("Finance")
    let words = problem(error, .copy(name: "a.txt"))

    #expect(words.message.hasPrefix(backupErrorWords(error) ?? "x"))
    #expect(words.message.hasSuffix(RestoreProblem.untouched))
    #expect(words.title == "Couldn't restore a.txt")
    #expect(problem(error).title == "Couldn't restore from Google Drive")
  }

  @Test func notEnoughRoomGivesBothSizesAndAWayOutForAFolder() {
    let error = BackupBuff.Failure.notEnoughRoom(needed: 48_000_000_000, available: 12_300_000_000)
    let folder = problem(error, .folder(name: "Documents"))
    let copy = problem(error, .copy(name: "a.txt"))

    #expect(folder.message.contains(bytes(48_000_000_000)))
    #expect(folder.message.contains(bytes(12_300_000_000)))
    #expect(folder.fix == .chooseFolder)
    // A copy lands beside its original: another folder is no way out.
    #expect(copy.fix == .none)
    #expect(!copy.message.contains("choose a folder"))
  }

  @Test func aFolderThatCantBeWrittenToAsksForAnother() {
    let found = problem(
      BackupBuff.Failure.cannotWrite(URL(fileURLWithPath: "/Volumes")), .folder(name: "T7"))

    #expect(found.fix == .chooseFolder)
    #expect(found.message.contains("Volumes"))
    #expect(found.message.contains("Choose another folder"))
  }

  @Test func eachPasswordFailureAsksForThePasswordExceptForACopy() {
    #expect(problem(BackupBuff.Failure.passwordNeeded).fix == .enterPassword)
    #expect(problem(BackupBuff.Failure.passwordDoesNotOpen).fix == .enterPassword)
    let copy = problem(BackupBuff.Failure.passwordNeeded, .copy(name: "a.txt"))
    #expect(copy.fix == .none)
    #expect(copy.message.contains("only from this Mac's Keychain and can't ask for it"))
    #expect(copy.message.contains("Restore Folder asks"))
  }

  @Test func theAccountsStatesSayWhatToDo() {
    #expect(problem(DriveProblem.signedOut).fix == .signIn)
    #expect(problem(BackupBuff.Failure.accountProblem(.signedOut)).fix == .signIn)
    #expect(problem(BackupBuff.Failure.accountProblem(.otherAccount)).fix == .chooseAccount)
    #expect(problem(BackupBuff.Failure.accountProblem(.unconfirmed)).fix == .chooseAccount)
    #expect(problem(DriveAccount.Failure.backupInAnotherAccount).fix == .chooseAccount)
    #expect(problem(DriveProblem.unreachable).fix == .tryAgain)
    #expect(problem(DriveProblem.unreachable).message.contains("can't be reached"))
    #expect(problem(BackupBuff.Failure.accountProblem(.full)).message.contains("full"))
    #expect(problem(BackupBuff.Failure.accountProblem(.backupGone)).message.contains("Bin"))
    #expect(
      problem(BackupBuff.Failure.accountProblem(.backupInBin)).message.contains("Put it back"))
    #expect(
      problem(BackupBuff.Failure.accountProblem(.otherAccount)).message.contains(
        "another Google account"))
  }

  @Test func onlyASignInIsAButtonOfAnAlert() {
    #expect(RestoreProblem.Fix.signIn.isSignIn)
    #expect(RestoreProblem.Fix.chooseAccount.isSignIn)
    #expect(!RestoreProblem.Fix.chooseFolder.isSignIn)
    let alert = BackupAlert.restoreProblem(problem(DriveAccount.Failure.backupInAnotherAccount))
    #expect(alert.buttons == ["Choose Account…", "Close"])
    #expect(BackupAlert.restoreProblem(problem(DriveProblem.unreachable)).buttons == ["OK"])
  }

  @Test func theKitsOwnFailuresReadAsSentencesWithWhatToDo() {
    let failures: [BackupBuff.Failure] = [
      .nothingToRestore, .notInBackup("a/b.txt"), .outsideFolder("a/b"), .seriesShared("x"),
      .backupIsEmpty,
    ]
    for failure in failures {
      let words = problem(failure, .copy(name: "b.txt"))
      #expect(words.message.count > 60)
      #expect(!words.message.contains("BackupBuff"))
    }
    #expect(problem(BackupBuff.Failure.notInBackup("a/b.txt")).message.hasPrefix("a/b.txt isn't"))
    #expect(problem(BackupBuff.Failure.backupIsEmpty).fix == .tryAgain)
  }

  @Test func resticAndUnknownErrorsSayNothingWasChanged() {
    let stalled = problem(ResticFailure.stalled(.noProgress(for: .seconds(60))))
    let exited = problem(ResticFailure.exited(.failed, message: "boom"))
    let other = problem(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "No."]))

    for words in [stalled, exited] {
      #expect(words.message.contains(RestoreProblem.untouched))
      #expect(words.fix == .tryAgain)
    }
    #expect(other.message == "No. \(RestoreProblem.untouched)")
    #expect(exited.message.contains("boom"))
  }

  @Test func aFullDiskReadsAsOne() {
    let error = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue))

    #expect(problem(error, .folder(name: "Documents")).message.contains("ran out of room"))
    #expect(problem(error, .folder(name: "Documents")).fix == .chooseFolder)
  }

  @Test func noWordsPutAnApostropheSOnAFolderName() {
    let words = problem(
      BackupBuff.Failure.notInBackup("Documents/a.txt"), .folder(name: "Documents"))

    #expect(!words.title.contains("Documents’s"))
    #expect(!words.message.contains("Documents's"))
  }
}

@Suite struct RestoreFolderStateTests {
  @Test func theDatesRunNewestFirstWithTheLatestMarked() throws {
    let dates = RestoreDate.list(
      [
        try snapshot("old", secondsAgo: 5 * day, bytes: 1_000_000),
        try snapshot("new", secondsAgo: 60, bytes: 2_000_000),
      ], now: now, calendar: calendar)

    #expect(dates.map(\.id) == ["new", "old"])
    #expect(dates[0].detail == "Latest backup · \(bytes(2_000_000))")
    #expect(dates[1].detail == bytes(1_000_000))
  }

  @Test func theSheetsWordsNameTheFolderAndPromiseNoReplacement() {
    let state = RestoreFolderState(folderName: "Documents", folderPath: "\(home)/Documents")

    #expect(state.explanation.contains("Nothing in Documents is replaced"))
    #expect(!state.explanation.contains("Documents’s"))
  }
}

@Suite struct RestoreRunTests {
  private func progress(_ json: String) throws -> RestoreProgress {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(RestoreProgress.self, from: Data(json.utf8))
  }

  @Test func theBytesAreTheMeasure() throws {
    let run = RestoreRun(
      folderName: "Documents", path: "/x",
      progress: try progress(
        #"{"percent_done":0.9,"total_files":10,"files_restored":4,"total_bytes":1000000000,"bytes_restored":250000000}"#
      ))

    #expect(run.fraction == 0.25)
    #expect(run.counts == "\(amountOf(250_000_000, 1_000_000_000)) · 4 of 10 files")
  }

  @Test func beforeTheFirstReportThereAreNoFigures() {
    let run = RestoreRun(folderName: "Documents", path: "/x")

    #expect(run.fraction == 0)
    #expect(run.counts == nil)
  }

  @Test func theRunTakesThePopoversTopWithItsOwnHeadline() {
    let run = RestoreRun(folderName: "Documents", path: "/x")
    let state = PopoverState(folders: [], restore: run, licence: .licensed, now: now)

    #expect(state.headline == "Restoring Documents")
    #expect(state.run?.isRestoring == true)
  }
}

@Suite struct RestoreFromDriveStateTests {
  private let other = BackedUpMac(id: "m", name: "Mei’s MacBook Pro", isThisMac: false)
  private let this = BackedUpMac(id: "t", name: "Mei’s Mac mini", isThisMac: true)

  private func folder(_ series: String, name: String, ago: [TimeInterval]) throws
    -> BackedUpFolder
  {
    BackedUpFolder(
      series: series, name: name, path: "\(home)/\(name)",
      snapshots: try ago.enumerated().map {
        try snapshot("\(series)\($0.offset)", secondsAgo: $0.element)
      }
    )
  }

  @Test func theFirstFolderAndItsNewestDateAreChosen() throws {
    let docs = try folder("docs", name: "Documents", ago: [3 * day, day])
    let pick = FolderPick(
      folders: [docs, try folder("pics", name: "Pictures", ago: [60])], destination: "/x",
      destinationName: "~")

    #expect(pick.selectedSeries == "docs")
    #expect(pick.snapshot?.id == "docs1")
    #expect(pick.dates(now: now, calendar: calendar).map(\.id) == ["docs1", "docs0"])
  }

  @Test func choosingAnotherFolderChoosesItsNewestDate() throws {
    var pick = FolderPick(
      folders: [
        try folder("docs", name: "Documents", ago: [day]),
        try folder("pics", name: "Pictures", ago: [9 * day, 60]),
      ], destination: "/x", destinationName: "~")

    pick.select(series: "pics")

    #expect(pick.folder?.name == "Pictures")
    #expect(pick.snapshot?.id == "pics1")
  }

  @Test func keepBackingUpHereSaysWhatItDoesBeforeItHappens() {
    let state = RestoreFromDriveState(account: "mei.chan@gmail.com", mac: other, step: .restored)
    let text = state.keepExplanation.joined(separator: " ")

    #expect(text.contains("takes over Mei’s MacBook Pro’s backup"))
    #expect(text.contains("That backup is in mei.chan@gmail.com’s Drive"))
    #expect(text.contains("that account is the one this Mac backs up to"))
    #expect(text.contains("nothing you restored is uploaded again"))
    #expect(text.contains("stays in Google Drive"))
    #expect(text.contains("switch Backup off on Mei’s MacBook Pro"))
  }

  @Test func onThisMacsOwnBackupItJustContinuesTheHistory() {
    let state = RestoreFromDriveState(mac: this, step: .restored)

    #expect(state.keepExplanation.count == 2)
    #expect(!state.keepExplanation.joined().contains("takes over"))
  }

  @Test func theHeadingFollowsTheStep() throws {
    let restored = RestoredFolder(
      name: "Documents (20 Oct 2026)", path: "/x",
      source: try folder("docs", name: "Documents", ago: [day]))

    #expect(
      RestoreFromDriveState(mac: other, step: .loadingMacs).title == "Restore from Google Drive")
    #expect(
      RestoreFromDriveState(mac: other, step: .loadingFolders).title
        == "Restore from Mei’s MacBook Pro")
    #expect(
      RestoreFromDriveState(mac: this, step: .loadingFolders).title == "Restore from this Mac")
    #expect(
      RestoreFromDriveState(
        mac: other, restored: [restored], step: .restored
      ).title == "Documents (20 Oct 2026) is back")
    #expect(
      RestoreFromDriveState(step: .password(PasswordAsk(macName: "Mei’s Mac")))
        .title == "Mei’s Mac’s backup has a password")
  }

  @Test func thePasswordPromptSaysItIsKeptOnlyIfTheBackupIsTakenOver() {
    let ask = PasswordAsk(macName: "x")

    #expect(ask.explanation.contains("only if you choose Keep Backing Up Here"))
    #expect(ask.wrongSentence.contains("doesn't open"))
    let forFolder = PasswordAsk(macName: "x", isForRestoreFolder: true)
    #expect(forFolder.explanation.contains("doesn't keep it"))
    #expect(!forFolder.explanation.contains("Keep Backing Up Here"))
  }

  @Test func versionsAreAPageOverTheFolder() {
    #expect(
      MainNavigation(opening: .versions(7)) == MainNavigation(.folder(7), path: [.versions(7)]))
    #expect(
      MainNavigation(.folder(7), path: [.versions(7)]).keeping(folders: []) == MainNavigation())
  }
}

@Suite struct RestoreSelectionTests {
  private let other = BackedUpMac(id: "m", name: "Mei’s MacBook Pro", isThisMac: false)
  private let this = BackedUpMac(id: "t", name: "Mei’s Mac mini", isThisMac: true)

  private func dates() throws -> [RestoreDate] {
    RestoreDate.list(
      [try snapshot("old", secondsAgo: 5 * day), try snapshot("new", secondsAgo: 60)], now: now,
      calendar: calendar)
  }

  @Test func aSheetOpenedWhileLoadingHasTheNewestDateSelectedOnceTheyArrive() throws {
    var state = RestoreFolderState(folderName: "Documents", folderPath: "\(home)/Documents")
    #expect(state.selectedDateID == nil)

    state.step = .choose(try dates())

    #expect(state.selectedDateID == "new")
  }

  @Test func aPickedDateStaysSelectedAndOneThatIsGoneFallsBackToTheNewest() throws {
    var state = RestoreFolderState(
      folderName: "Documents", folderPath: "\(home)/Documents", step: .choose(try dates()))

    state.pickedDateID = "old"
    #expect(state.selectedDateID == "old")

    state.pickedDateID = "forgotten"
    #expect(state.selectedDateID == "new")
  }

  @Test func theDatesAreNotSelectedOutsideTheChoice() {
    var state = RestoreFolderState(folderName: "Documents", folderPath: "\(home)/Documents")
    state.pickedDateID = "old"

    #expect(state.selectedDateID == nil)
  }

  @Test func theMacsListHasAnotherMacsBackupSelectedWhenItArrives() {
    var state = RestoreFromDriveState()
    #expect(state.selectedMacID == nil)

    state.step = .macs([this, other])
    #expect(state.selectedMacID == "m")

    state.pickedMacID = "t"
    #expect(state.selectedMacID == "t")

    state.step = .macs([this])
    state.pickedMacID = "gone"
    #expect(state.selectedMacID == "t")
  }

  private func folder() throws -> BackedUpFolder {
    BackedUpFolder(
      series: "docs", name: "Documents", path: "\(home)/Documents",
      snapshots: [try snapshot("s", secondsAgo: day)])
  }

  @Test func onlyTheNewestRestoreOfASeriesContinuesItAndTheSheetSaysSo() throws {
    let source = try folder()
    let older = RestoredFolder(
      name: "Documents (older)", path: "/a", source: source,
      savedAt: now.addingTimeInterval(-9 * day))
    let newer = RestoredFolder(
      name: "Documents (newer)", path: "/b", source: source,
      savedAt: now.addingTimeInterval(-1 * day))
    let pictures = RestoredFolder(
      name: "Pictures (older)", path: "/c",
      source: BackedUpFolder(series: "pics", name: "Pictures", path: "/p", snapshots: []),
      savedAt: now.addingTimeInterval(-3 * day))
    let state = RestoreFromDriveState(
      mac: other, restored: [older, newer, pictures], step: .restored)

    #expect(Set(state.continuing.map(\.path)) == ["/b", "/c"])
    #expect(state.plainCopies.map(\.path) == ["/a"])
    #expect(state.keepExplanation.joined(separator: " ").contains("Documents (older)"))
    #expect(state.keepExplanation.joined(separator: " ").contains("Documents (newer)"))
  }

  @Test func oneRestorePerSeriesNeedsNoSuchSentence() throws {
    let restored = RestoredFolder(name: "Documents (x)", path: "/a", source: try folder())
    let state = RestoreFromDriveState(mac: other, restored: [restored], step: .restored)

    #expect(state.plainCopies.isEmpty)
    #expect(state.continuing.map(\.path) == ["/a"])
    #expect(!state.keepExplanation.joined().contains("plain copy"))
  }
}

@Suite struct RestoreGateTests {
  @Test func aRestoreThatIsReplacedOrEndedIsNoLongerCurrent() {
    var gate = RestoreGate()
    let first = gate.begin()
    #expect(gate.isCurrent(first))

    let second = gate.begin()
    #expect(!gate.isCurrent(first))
    #expect(gate.isCurrent(second))

    gate.end()
    #expect(!gate.isCurrent(second))
    #expect(!gate.isCurrent(UUID()))
  }
}
