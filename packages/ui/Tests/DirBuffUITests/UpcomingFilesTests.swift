import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func preview(
  _ settings: TemporarySettings = TemporarySettings(),
  items: [Item] = [],
  dueNow: [Item] = [],
  upcoming: [(Item, TimeInterval)] = []
) -> FolderPreview {
  guard let status = report(1, items: items, dueNow: dueNow, upcoming: upcoming).status else {
    preconditionFailure("report(1) is readable")
  }
  return FolderPreview(status, settings: settings, now: now, calendar: calendar, binName: "Bin")
}

/// A time of day as the app writes it, whatever the Mac's clock style.
private func clock(_ date: Date) -> String {
  date.formatted(
    Date.FormatStyle(
      date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
}

/// A day as the app writes it, whatever the Mac's language: "Sat 17 Oct" in UK English.
private func dayAndDate(_ date: Date) -> String {
  date.formatted(dateStyle.weekday(.abbreviated).day().month(.abbreviated))
}

/// A weekday as the app writes it: "Sat".
private func weekday(_ date: Date) -> String {
  date.formatted(dateStyle.weekday(.abbreviated))
}

private let dateStyle = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)

// The fixtures' `now` is Thu 08:00, so the next clean-up is at 09:00, an hour away.

@Suite struct UpcomingFiles {
  @Test func groupsTheNextCleanUpTheNextDayAndLater() {
    let groups = preview(
      dueNow: [item("a"), item("b")],
      upcoming: [(item("c"), 2 * oneDay), (item("d"), 2 * oneDay), (item("e"), 9 * oneDay)]
    ).files
    #expect(groups.map(\.kind) == [.nextCleanUp, .nextDay, .later])
    #expect(
      groups.map(\.title) == [
        "Today, \(clock(now.addingTimeInterval(3_600)))", dayAndDate(now + 2 * oneDay), "Later",
      ])
    #expect(groups.map { $0.files.map(\.name) } == [["a", "b"], ["c", "d"], ["e"]])
  }

  @Test func summarisesEachGroupInNumbers() {
    let groups = preview(
      dueNow: [item("a", size: 1_000), item("b", size: 2_000)],
      upcoming: [(item("c"), 2 * oneDay), (item("d"), 9 * oneDay)]
    ).files
    #expect(groups[0].summary == "2 items · \(bytes(3_000))")
    #expect(groups[1].summary == "1 item · \(bytes(1_000))")
    #expect(groups[2].summary == "1 item · \(bytes(1_000)) · from \(dayAndDate(now + 9 * oneDay))")
  }

  @Test func namesWhenEachFileGoesAndWasAdded() {
    let old = Item(
      url: URL(fileURLWithPath: "\(home)/F/old"), freshness: now - 20 * oneDay, size: 5)
    let files = preview(
      dueNow: [old], upcoming: [(item("soon"), 2 * oneDay), (item("far"), 9 * oneDay)]
    ).files.flatMap(\.files)
    let nine = clock(now.addingTimeInterval(3_600))
    #expect(
      files.map(\.goes) == [
        "Today, \(nine)", "\(weekday(now + 2 * oneDay)), \(nine)",
        "\(dayAndDate(now + 9 * oneDay)), \(nine)",
      ])
    #expect(files[0].added == dayAndDate(now - 20 * oneDay))
    #expect(files[0].size == bytes(5))
  }

  @Test func saysTheRestOfTheDayWhenTheNextDayIsTheSameDay() {
    let groups = preview(dueNow: [item("a")], upcoming: [(item("b"), 3_600 * 3)]).files
    #expect(groups.map(\.kind) == [.nextCleanUp, .nextDay])
    #expect(groups[1].title == "Later today")
  }

  @Test func tellsTomorrowApart() {
    let groups = preview(upcoming: [(item("a"), oneDay), (item("b"), 2 * oneDay)]).files
    #expect(
      groups.map(\.title) == [
        "Tomorrow, \(clock(now.addingTimeInterval(3_600)))", dayAndDate(now + 2 * oneDay),
      ])
  }

  @Test func leavesOutGroupsWithNothingInThem() {
    #expect(preview(dueNow: [item("a")]).files.map(\.kind) == [.nextCleanUp])
    #expect(preview().files.isEmpty)
  }

  @Test func listsEveryFileOfAGroupInNameOrder() {
    let files = preview(dueNow: [item("c"), item("a"), item("b")]).files[0].files
    #expect(files.map(\.name) == ["a", "b", "c"])
  }

  @Test func putsEmptyOnRestartsFilesInOneGroupAfterTheOthers() {
    let groups = preview(
      TemporarySettings(rule: .emptyOnRestart),
      items: [item("kept")]
    ).files
    #expect(groups.map(\.kind) == [.restart])
    #expect(groups[0].title == "At restart")
    #expect(groups[0].files.map(\.goes) == ["At restart"])
  }

  @Test func listsAFileAlreadyDueOnlyAtTheNextCleanUp() {
    let due = item("due")
    let groups = preview(
      TemporarySettings(rule: .emptyOnRestart),
      items: [due, item("kept")],
      dueNow: [due]
    ).files
    #expect(groups.map(\.kind) == [.nextCleanUp, .restart])
    #expect(groups.map { $0.files.map(\.name) } == [["due"], ["kept"]])
  }

  @Test func leavesOutWhatNoDateOrRuleReaches() {
    let undated = Item(url: URL(fileURLWithPath: "\(home)/F/undated"), freshness: nil, size: 1)
    #expect(preview(TemporarySettings(rule: .emptyOnRestart), items: [undated]).files.isEmpty)
    #expect(preview(items: [item("kept")]).files.isEmpty)
  }
}

@Suite struct FilesSearch {
  private let groups = preview(
    dueNow: [item("Report.pdf"), item("photo.png")],
    upcoming: [(item("report-2.pdf"), 2 * oneDay), (item("zip.zip"), 9 * oneDay)]
  ).files

  @Test func keepsTheFilesWhoseNameHasTheText() {
    let matches = groups.matching("report")
    #expect(matches.map(\.kind) == [.nextCleanUp, .nextDay])
    #expect(matches.map { $0.files.map(\.name) } == [["Report.pdf"], ["report-2.pdf"]])
  }

  @Test func keepsEverythingForABlankSearch() {
    #expect(groups.matching("") == groups)
  }

  @Test func findsNothingForAStrangerName() {
    #expect(groups.matching("nope").isEmpty)
  }
}

@Suite struct FilesEmptinessWording {
  @Test(
    arguments: [
      (
        FilesEmptiness.cantRead, "Can't read this folder",
        "DirBuff needs access to show and clean its files."
      ),
      (.isPaused, "Cleaning is paused", "No files will be cleaned while it's paused."),
      (.isNotTemporary, "Temporary is off for this folder", "No files will be cleaned from it."),
      (.nothingGoesNext, "No files due for cleaning", "Files will appear here when they're due."),
    ])
  func saysWhyInTwoLines(emptiness: FilesEmptiness, title: String, detail: String) {
    #expect(emptiness.title == title)
    #expect(emptiness.detail == detail)
  }
}

@Suite struct FilesEmptinessReasons {
  private func folder(_ report: FolderReport, isPaused: Bool = false) -> FilesEmptiness? {
    MainState(
      reports: [report], licence: .licensed, now: now, calendar: calendar, binName: "Bin",
      home: home, startupVolumeName: "Macintosh HD"
    ).folders[0].filesEmptiness(isPaused: isPaused)
  }

  @Test func isNilWhileSomethingGoesNext() {
    #expect(folder(report(1, dueNow: [item("a")])) == nil)
  }

  @Test func saysNothingGoesNext() {
    #expect(folder(report(1)) == .nothingGoesNext)
  }

  @Test func saysItCantReadAnUnreadableFolder() {
    #expect(folder(report(1, problem: .unreachable)) == .cantRead)
  }

  @Test func saysCleaningIsPausedBeforeAnythingElse() {
    #expect(folder(report(1, problem: .unreachable), isPaused: true) == .isPaused)
  }

  @Test func saysCleaningIsPaused() {
    #expect(folder(report(1, dueNow: [item("a")]), isPaused: true) == .isPaused)
  }

  @Test func saysTemporaryIsOff() {
    #expect(folder(report(1, wearsTemporary: false)) == .isNotTemporary)
  }
}

@Suite struct FilesProblems {
  private func problem(_ report: FolderReport, licence: Licence = .licensed) -> FilesProblem? {
    FolderState.all([report], licence: licence, now: now, calendar: calendar, home: home)
      .first.flatMap { FilesProblem($0, now: now) }
  }

  @Test func saysMacOSTookAwayAccessAndSinceWhen() {
    let lost = report(1, problem: .noAccess, accessLostAt: now.addingTimeInterval(-3 * oneDay))
    #expect(problem(lost)?.sentence == "macOS took away access 3 days ago")
    #expect(problem(lost)?.fix == .giveAccess)
    #expect(problem(lost)?.folderName == nil)
  }

  @Test func saysMacOSTookAwayAccessWithoutSinceWhenUnknown() {
    #expect(problem(report(1, problem: .noAccess))?.sentence == "macOS took away access")
  }

  @Test func saysItCantFindAMissingFolderAndOffersToLocateIt() {
    let missing = problem(report(1, name: "Projects", problem: .missing, missingSince: now))
    #expect(missing?.sentence == "Can't find")
    #expect(missing?.folderName == "Projects")
    #expect(missing?.detail?.hasPrefix("Missing since") == true)
    #expect(missing?.fix == .locate)
  }

  @Test func saysADriveIsntConnectedWithNothingToFix() {
    let unplugged = problem(report(1, path: "/Volumes/T7 Shuttle/Downloads", problem: .unreachable))
    #expect(unplugged?.sentence == "T7 Shuttle isn't connected")
    #expect(unplugged?.fix == nil)
  }

  @Test func hasNothingToSayAboutAReadableFolder() {
    #expect(problem(report(1)) == nil)
  }

  @Test func leavesAPausedLicenceToTheFilesPage() {
    #expect(problem(report(1, problem: .noAccess), licence: .trialEnded) == nil)
  }
}
