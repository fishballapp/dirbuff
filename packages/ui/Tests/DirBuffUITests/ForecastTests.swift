import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func groups(_ reports: [FolderReport], at moment: Date = now) -> [ForecastGroup] {
  forecastGroups(
    reports.compactMap { report in report.status.map { (report.folder.settings, $0) } },
    now: moment,
    calendar: calendar,
    binName: "Bin"
  )
}

// The fixtures' `now` is 08:00, so the next clean-up is at 09:00, an hour away.

@Suite struct Forecast {
  @Test func listsUndoableBeforePermanentThenByMoment() {
    let deleting = TemporarySettings(rule: .emptyOnRestart, disposal: .delete)
    let forecast = groups([
      report(1, dueNow: [item("a")], upcoming: [(item("b"), oneDay)]),
      report(
        2, deleting,
        items: [item("kept"), Item(url: URL(fileURLWithPath: "/u"), freshness: nil, size: 1)],
        dueNow: [item("c")]),
    ])
    #expect(
      forecast.map(\.header) == [
        "In 1 hr · Move to Bin", "Tomorrow · Move to Bin", "In 1 hr · Delete Permanently",
        "After a restart · Delete Permanently",
      ])
    #expect(forecast.map(\.isPermanent) == [false, false, true, true])
    #expect(forecast.map(\.isAtRestart) == [false, false, false, true])
    #expect(forecast.last?.names == ["kept"])
  }

  @Test func countsDownToTodaysCleanUps() {
    let forecast = groups([
      report(1, dueNow: [item("due")], upcoming: [(item("soon"), 1_800), (item("later"), 7_200)])
    ])
    #expect(
      forecast.map(\.when) == [
        "In 1 hr", "In 3 hr",
      ])
    #expect(forecast[0].names == ["due", "soon"])
  }

  @Test func countsDownToMidnightsCleanUp() {
    // Due at 23:30, so it clears at midnight: still today's last clean-up, not "Tomorrow".
    let forecast = groups([report(1, upcoming: [(item("late"), 15.5 * 3_600)])])
    #expect(forecast.map(\.when) == ["In 16 hr"])
  }

  @Test func namesEveryItemAndTotalsTheirSize() {
    let group = groups([report(1, dueNow: (1...5).map { item("\($0)", size: 2_000) })])[0]
    #expect(group.names == ["1", "2", "3", "4", "5"])
    #expect(group.totalSize == bytes(10_000))
  }

  @Test func looksOnlyAWeekAhead() {
    #expect(groups([report(1, upcoming: [(item("far"), 20 * oneDay)])]).isEmpty)
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
    let forecast = groups(
      [report(1, dueNow: [item("a")])],
      at: now.addingTimeInterval(3_558)
    )
    #expect(forecast.map(\.when) == ["In 42 sec"])
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

  @Test func countsWhatClearsThisWeekOnce() {
    #expect(preview(dueNow: [item("a"), item("b")]).headline == "2 items to clear in 1 hr")
    #expect(
      preview(dueNow: [item("a")], upcoming: [(item("b"), 2 * oneDay)]).headline
        == "2 items to clear this week")
  }

  @Test func saysWhatHappensToEachGroup() {
    let deleting = TemporarySettings(rule: .emptyOnRestart, disposal: .delete)
    let forecast = preview(deleting, items: [item("kept")], dueNow: [item("old")]).forecast
    #expect(
      forecast.map(\.header) == [
        "In 1 hr · Delete Permanently", "After a restart · Delete Permanently",
      ])
  }

  @Test func saysWhenTheOldestClearsWhenNothingClearsThisWeek() {
    #expect(
      preview(upcoming: [(item("a"), 20 * oneDay)]).headline
        == "Nothing to clear this week. The oldest item is cleared in 20 days.")
    #expect(preview().headline == "Nothing to clear this week.")
  }
}
