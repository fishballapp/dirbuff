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

@Suite struct RestoreProblemTests {
  private func problem(_ error: any Error, _ subject: RestoreProblem.Subject = .backup)
    -> RestoreProblem
  {
    RestoreProblem(error, while: subject)
  }

  @Test func theWordsAreBackupErrorWordsWithWhatToDoAndThatNothingChanged() {
    let error = BackupBuff.Failure.outsideFolder("Finance")
    let words = problem(error, .item(name: "a.txt"))

    #expect(words.message.hasPrefix(backupErrorWords(error) ?? "x"))
    #expect(words.message.hasSuffix(RestoreProblem.untouched))
    #expect(words.title == "Couldn't restore a.txt")
    #expect(problem(error).title == "Couldn't restore from Google Drive")
  }

  @Test func notEnoughRoomGivesBothSizesAndAWayOutForAFolder() {
    let error = BackupBuff.Failure.notEnoughRoom(needed: 48_000_000_000, available: 12_300_000_000)
    let folder = problem(error, .folder(name: "Documents"))
    let copy = problem(error, .item(name: "a.txt"))

    #expect(folder.message.contains(bytes(48_000_000_000)))
    #expect(folder.message.contains(bytes(12_300_000_000)))
    #expect(folder.fix == .chooseFolder)
    // An item goes back where it was: another folder is no way out.
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

  @Test func eachPasswordFailureAsksForThePassword() {
    #expect(problem(BackupBuff.Failure.passwordNeeded).fix == .enterPassword)
    #expect(problem(BackupBuff.Failure.passwordDoesNotOpen).fix == .enterPassword)
    #expect(problem(BackupBuff.Failure.passwordNeeded, .item(name: "a.txt")).fix == .enterPassword)
  }

  @Test func onlyWhatWouldHaveWrittenSaysNothingWasChanged() {
    let offline = DriveProblem.unreachable
    #expect(problem(offline, .listing).message == backupErrorWords(offline))
    #expect(problem(offline, .listing).fix == .tryAgain)
    #expect(!problem(offline, .preview(name: "a.pdf")).message.contains(RestoreProblem.untouched))
    #expect(problem(offline, .preview(name: "a.pdf")).title == "Couldn't preview a.pdf")
    #expect(problem(offline, .item(name: "a.pdf")).message.hasSuffix(RestoreProblem.untouched))
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
      .notInBackup("a/b.txt"), .outsideFolder("a/b"), .seriesShared("x"),
      .backupIsEmpty,
    ]
    for failure in failures {
      let words = problem(failure, .item(name: "b.txt"))
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
    let thisMac = PasswordAsk(macName: "x", isForThisMac: true)
    #expect(thisMac.explanation.contains("doesn't keep it"))
    #expect(!thisMac.explanation.contains("Keep Backing Up Here"))
  }

  @Test func versionsAreAPageOverTheFolder() {
    #expect(
      MainNavigation(opening: .backup(7)) == MainNavigation(.folder(7), path: [.backup(7)]))
    #expect(
      MainNavigation(.folder(7), path: [.backup(7)]).keeping(folders: []) == MainNavigation())
  }
}

@Suite struct RestoreSelectionTests {
  private let other = BackedUpMac(id: "m", name: "Mei’s MacBook Pro", isThisMac: false)
  private let this = BackedUpMac(id: "t", name: "Mei’s Mac mini", isThisMac: true)

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
