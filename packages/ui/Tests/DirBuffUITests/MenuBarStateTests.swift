import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func state(_ reports: [FolderReport], journal: [JournalEntry] = []) -> MenuBarState {
  MenuBarState(
    reports: reports, journal: journal, freeSpace: 50_000_000_000, isFinderExtensionOff: false,
    licence: .licensed, now: now, calendar: calendar, binName: "Bin")
}

// The fixtures' `now` is 08:00, so the next clean-up is at 09:00, an hour away.

@Suite struct Forecast {
  @Test func listsUndoableBeforePermanentThenByMoment() {
    let deleting = TemporarySettings(rule: .emptyOnRestart, disposal: .delete)
    let menu = state([
      report(1, dueNow: [item("a")], upcoming: [(item("b"), oneDay)]),
      report(
        2, deleting,
        items: [item("kept"), Item(url: URL(fileURLWithPath: "/u"), freshness: nil, size: 1)],
        dueNow: [item("c")]),
    ])
    #expect(
      menu.forecast.map(\.header) == [
        "In 1 hr · Move to Bin", "Tomorrow · Move to Bin", "In 1 hr · Delete Permanently",
        "After a restart · Delete Permanently",
      ])
    #expect(menu.forecast.map(\.isPermanent) == [false, false, true, true])
    #expect(menu.forecast.map(\.isAtRestart) == [false, false, false, true])
    #expect(menu.forecast.last?.names == ["kept"])
  }

  @Test func countsDownToTodaysCleanUps() {
    let menu = state([
      report(1, dueNow: [item("due")], upcoming: [(item("soon"), 1_800), (item("later"), 7_200)])
    ])
    #expect(
      menu.forecast.map(\.when) == [
        "In 1 hr", "In 3 hr",
      ])
    #expect(menu.forecast[0].names == ["due", "soon"])
  }

  @Test func countsDownToMidnightsCleanUp() {
    // Due at 23:30, so it goes at midnight: still today's last clean-up, not "Tomorrow".
    let menu = state([report(1, upcoming: [(item("late"), 15.5 * 3_600)])])
    #expect(
      menu.forecast.map(\.when) == ["In 16 hr"])
  }

  @Test func namesEveryItemAndTotalsTheirSize() {
    let group = state([report(1, dueNow: (1...5).map { item("\($0)", size: 2_000) })]).forecast[0]
    #expect(group.names == ["1", "2", "3", "4", "5"])
    #expect(group.totalSize == bytes(10_000))
  }

  @Test func looksOnlyAWeekAhead() {
    #expect(state([report(1, upcoming: [(item("far"), 20 * oneDay)])]).forecast.isEmpty)
  }

  @Test func skipsAFolderItCouldNotRead() {
    #expect(state([report(1, problem: .unreachable)]).forecast.isEmpty)
  }
}

@Suite struct Countdown {
  @Test(
    arguments: [
      (42.0, "42 sec"), (59.2, "1 min"), (60.0, "1 min"), (61.0, "2 min"), (23 * 60.0, "23 min"),
      (3_600.0, "1 hr"), (3_900.0, "1 hr 5 min"),
    ])
  func roundsUpToWhatIsLeft(seconds: TimeInterval, text: String) {
    #expect(timeLeft(until: now.addingTimeInterval(seconds), now: now) == text)
  }

  @Test func ticksEachMinuteThenEachSecondBeforeACleanUp() {
    let schedule = CountdownSchedule(calendar: calendar)
    // 08:00 is a clean-up; the next is 09:00.
    #expect(schedule.tick(after: now.addingTimeInterval(30)) == now.addingTimeInterval(60))
    let lastMinute = now.addingTimeInterval(59 * 60)
    #expect(schedule.tick(after: lastMinute) == lastMinute.addingTimeInterval(1))
    let lastSecond = now.addingTimeInterval(3_599)
    #expect(schedule.tick(after: lastSecond) == lastSecond.addingTimeInterval(1))
    #expect(schedule.tick(after: now.addingTimeInterval(3_600)) == now.addingTimeInterval(3_660))
  }

  @Test func countsDownInTheForecast() {
    let menu = MenuBarState(
      reports: [report(1, dueNow: [item("a")])], journal: [], freeSpace: 0,
      isFinderExtensionOff: false, licence: .licensed, now: now.addingTimeInterval(3_558),
      calendar: calendar, binName: "Bin")
    #expect(menu.headline == "1 item goes in 42 sec")
    #expect(menu.forecast.map(\.when) == ["In 42 sec"])
  }
}

@Suite struct Headline {
  @Test(
    arguments: [
      ([item("a"), item("b")], [], "2 items go in 1 hr"),
      ([], [(item("a"), 1_800.0)], "1 item goes in 1 hr"),
      ([], [(item("a"), 3_600.0)], "1 item goes today"),
      ([], [(item("a"), oneDay)], "1 item goes tomorrow"),
      ([], [(item("a"), 5 * oneDay)], "Nothing goes today"),
    ] as [([Item], [(Item, TimeInterval)], String)])
  func saysWhatGoesFirst(dueNow: [Item], upcoming: [(Item, TimeInterval)], headline: String) {
    #expect(state([report(1, dueNow: dueNow, upcoming: upcoming)]).headline == headline)
  }

  @Test func invitesTheFirstFolder() {
    let menu = state([])
    #expect(menu.hasNoFolders)
    #expect(menu.headline == "No Temporary folders yet")
  }
}

@Suite struct FolderRow {
  private func distance(_ report: FolderReport) -> String? {
    state([report]).folders.first?.distanceToGoing
  }

  @Test func saysHowCloseTheFolderIsToGoing() {
    #expect(distance(report(1, dueNow: [item("a")])) == "1 item goes in 1 hr")
    #expect(
      distance(report(1, upcoming: [(item("a"), 2.5 * 3_600)]))
        == "Oldest goes in 3 hr")
    #expect(distance(report(1, upcoming: [(item("a"), 2 * oneDay)])) == "Oldest goes in 2 days")
    let sized = TemporarySettings(rule: .size, sizeLimit: 10_000)
    #expect(
      distance(report(1, sized, items: [item("a", size: 4_000)]))
        == "\(bytes(4_000)) of \(bytes(10_000))")
    #expect(distance(report(1, items: [item("a")])) == "Nothing to clear")
  }

  @Test func saysWhenTheFolderCantBeCleared() {
    #expect(distance(report(1, problem: .unreachable)) == "Can't read this folder")
  }

  @Test func leavesOutFoldersThatAreOff() {
    #expect(distance(report(1, wearsTemporary: false)) == nil)
    let menu = state([report(1, wearsTemporary: false)])
    #expect(menu.folders.isEmpty)
    #expect(menu.hasNoFolders)
    #expect(menu.headline == "No Temporary folders yet")
  }
}

@Suite struct Recent {
  private func entry(
    _ id: Int64, folder: Int64 = 1, _ disposal: Disposal = .bin, at offset: TimeInterval,
    undone: Bool = false
  ) -> JournalEntry {
    JournalEntry(
      id: id, folderID: folder, disposal: disposal, name: "f\(id)", size: 1, reasons: [.age],
      performedAt: now.addingTimeInterval(offset), undoneAt: undone ? now : nil)
  }

  @Test func listsEachRunNewestFirst() {
    let runs = state(
      [report(1), report(2)],
      journal: [
        entry(1, at: -7_200), entry(2, at: -7_200), entry(3, folder: 2, .delete, at: -60),
      ]
    ).recentRuns
    #expect(runs.map(\.summary) == ["1 item deleted permanently", "2 items to the Bin"])
    #expect(runs.map(\.canPutBack) == [false, true])
    #expect(runs[1].journalEntryIDs == [1, 2])
    #expect(runs[1].putBackLabel == "Put 2 items back")
    #expect(runs[1].detail.hasPrefix("Folder1 · "))
  }

  @Test func namesTheDayOfARunBeforeToday() {
    let details = state(
      [report(1)],
      journal: [entry(1, at: -60), entry(2, at: -oneDay), entry(3, at: -3 * oneDay)]
    ).recentRuns.map(\.detail)
    #expect(!details[0].contains(","))
    #expect(details[1].hasPrefix("Folder1 · Yesterday, "))
    let threeDaysAgo = now.addingTimeInterval(-3 * oneDay)
      .formatted(
        Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
          .weekday(.abbreviated).day().month(.abbreviated))
    #expect(details[2].hasPrefix("Folder1 · \(threeDaysAgo), "))
  }

  @Test func showsARunThatWasPutBack() {
    let run = state([report(1)], journal: [entry(1, at: -60, undone: true)]).recentRuns[0]
    #expect(run.summary == "1 item put back")
    #expect(!run.canPutBack)
  }
}

@Suite struct Preview {
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

  @Test func countsWhatGoesThisWeekOnce() {
    #expect(preview(dueNow: [item("a"), item("b")]).headline == "2 items go in 1 hr")
    #expect(
      preview(dueNow: [item("a")], upcoming: [(item("b"), 2 * oneDay)]).headline
        == "2 items go this week")
  }

  @Test func saysWhatHappensToEachGroup() {
    let deleting = TemporarySettings(rule: .emptyOnRestart, disposal: .delete)
    let forecast = preview(deleting, items: [item("kept")], dueNow: [item("old")]).forecast
    #expect(
      forecast.map(\.header) == [
        "In 1 hr · Delete Permanently", "After a restart · Delete Permanently",
      ])
  }

  @Test func saysWhenTheOldestGoesWhenNothingGoesThisWeek() {
    #expect(
      preview(upcoming: [(item("a"), 20 * oneDay)]).headline
        == "Nothing goes this week. The oldest item goes in 20 days.")
    #expect(preview().headline == "Nothing goes this week.")
  }
}
