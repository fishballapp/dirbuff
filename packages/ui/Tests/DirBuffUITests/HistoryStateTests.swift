import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private let downloads = HistoryFolder(
  id: 1, name: "Downloads", path: "\(home)/Downloads", mark: .atRest)
private let screenshots = HistoryFolder(
  id: 2, name: "Screenshots", path: "\(home)/Screenshots", mark: nil)

/// A run that removed `items` items of `size` from each of `folders`.
private func run(
  _ id: Int64, at date: Date = now, folders: Set<Int64> = [1], items: Int = 1,
  size: Int64 = 1_000
) -> RunSummary {
  RunSummary(
    id: id, startedAt: date,
    shares: Dictionary(
      uniqueKeysWithValues: folders.map { ($0, .init(itemCount: items, size: size)) }))
}

private func entry(
  _ id: Int64,
  _ name: String,
  folder: Int64 = 1,
  _ disposal: Disposal = .bin,
  size: Int64 = 1_000,
  undoneAt: Date? = nil
) -> JournalEntry {
  JournalEntry(
    id: id, runID: 7, folderID: folder, disposal: disposal, name: name,
    binnedPath: disposal == .bin ? "\(home)/.Trash/\(name)" : nil, size: size, reasons: [.age],
    performedAt: now, undoneAt: undoneAt)
}

/// The time as the system's short style says it, as the app does.
private func clock(_ date: Date) -> String {
  date.formatted(
    Date.FormatStyle(
      date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
}

private let dateStyle = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)

/// A day as the app writes it, whatever the Mac's language: "Thu 15 Oct" in UK English.
private func dayAndDate(_ date: Date) -> String {
  date.formatted(dateStyle.weekday(.abbreviated).day().month(.abbreviated))
}

/// "2025".
private func year(_ date: Date) -> String {
  date.formatted(dateStyle.year())
}

@Suite struct HistoryListState {
  @Test func saysWhenEachRunWas() {
    let rows = [
      run(1, at: now), run(2, at: now - oneDay), run(3, at: now - 2 * oneDay),
      run(4, at: now - 300 * oneDay),
    ].map { HistoryRunRow($0, now: now, calendar: calendar) }

    #expect(
      rows.map(\.when) == [
        "Today \(clock(now))", "Yesterday \(clock(now))",
        "\(dayAndDate(now - 2 * oneDay)) \(clock(now))",
        "\(dayAndDate(now - 300 * oneDay)) \(year(now - 300 * oneDay)) \(clock(now))",
      ])
  }

  @Test func countsFoldersItemsAndBytes() {
    let many = HistoryRunRow(
      RunSummary(
        id: 1, startedAt: now,
        shares: [
          1: .init(itemCount: 5, size: 2_300_000_000), 2: .init(itemCount: 6, size: 24_000_000),
          3: .init(itemCount: 1, size: 1_076_000_000),
        ]), now: now, calendar: calendar)
    let one = HistoryRunRow(run(2, items: 1, size: 4_100_000), now: now, calendar: calendar)

    #expect(many.summary == "3 folders · 12 items · \(bytes(3_400_000_000))")
    #expect(one.summary == "1 folder · 1 item · \(bytes(4_100_000))")
    #expect(one.buff == .temporary)
  }

  @Test func showsOneFoldersRunsAndNamesIt() {
    let state = HistoryState(
      [run(1, folders: [1, 2]), run(2, folders: [2]), run(3, folders: [1])],
      folders: [downloads, screenshots], now: now, calendar: calendar)

    #expect(state.runs(touching: nil).map(\.id) == [1, 2, 3])
    #expect(state.runs(touching: 1).map(\.id) == [1, 3])
    #expect(state.runs(touching: nil).map(\.summary)[0] == "2 folders · 2 items · 2 kB")
    #expect(state.subtitle(for: nil) == "3 runs")
    #expect(state.subtitle(for: 1) == "Downloads · 2 runs")
    #expect(state.subtitle(for: 3) == "0 runs")
    #expect(HistoryState(runs: [], folders: []).subtitle(for: nil) == "0 runs")
    #expect(
      HistoryState([run(1)], folders: [], now: now, calendar: calendar).subtitle(for: nil)
        == "1 run")
  }

  @Test func oneFoldersHistoryShowsItsShareOfEachRun() {
    let state = HistoryState(
      [
        RunSummary(
          id: 1, startedAt: now,
          shares: [
            1: .init(itemCount: 5, size: 2_300_000_000), 2: .init(itemCount: 6, size: 24_000_000),
          ])
      ], folders: [downloads, screenshots], now: now, calendar: calendar)

    #expect(state.runs(touching: nil).map(\.summary) == ["2 folders · 11 items · 2.32 GB"])
    #expect(state.runs(touching: 1).map(\.summary) == ["5 items · 2.3 GB"])
    #expect(state.runs(touching: 2).map(\.summary) == ["6 items · 24 MB"])
  }

  @Test func namesEveryFolderWithItsMark() {
    let reports = [
      report(1, name: "Downloads", path: "\(home)/Downloads"),
      report(2, name: "Screenshots", path: "\(home)/Screenshots", wearsTemporary: false),
    ]
    let states = FolderState.all(reports, licence: .trial(daysLeft: 9), now: now)

    #expect(HistoryFolder.all(reports, states: states) == [downloads, screenshots])
  }
}

@Suite struct RunPageState {
  private func state(
    _ entries: [JournalEntry], inBin: Set<Int64>
  ) -> RunState {
    RunState(
      RunSummary(
        id: 7, startedAt: now,
        shares: Dictionary(grouping: entries, by: \.folderID).mapValues {
          .init(itemCount: $0.count, size: $0.reduce(0) { $0 + $1.size })
        }),
      entries: entries, folders: [downloads, screenshots], inBin: inBin, now: now,
      calendar: calendar, binName: "Bin")
  }

  @Test func saysWhereEachFileWent() {
    let page = state(
      [
        entry(1, "tickets-export.csv"), entry(2, "Sketch-99.dmg"),
        entry(3, "boarding-pass.pdf", undoneAt: now + 3_600),
        entry(4, "invoice-sept.pdf", undoneAt: now - oneDay),
        entry(5, "Render-v2-final.mov", .delete),
      ], inBin: [1, 3])
    let files = page.groups[0].files

    #expect(
      files.map(\.name) == [
        "boarding-pass.pdf", "invoice-sept.pdf", "Render-v2-final.mov", "Sketch-99.dmg",
        "tickets-export.csv",
      ])
    #expect(
      files.map(\.status) == [
        "Put back today, \(clock(now + 3_600))", "Put back yesterday, \(clock(now))",
        "Deleted permanently", "Emptied from the Bin", "In the Bin",
      ])
    #expect(files.map(\.isInBin) == [false, false, false, false, true])
    #expect(files[4].binnedPath == "\(home)/.Trash/tickets-export.csv")
    #expect(page.groups[0].putBackEntryIDs == [1])
  }

  @Test func groupsByFolderInTheirOrderAndSumsUp() {
    let page = state(
      [
        entry(1, "a.png", folder: 2, size: 4_000_000), entry(2, "b.mov", size: 1_600_000_000),
        entry(3, "c.pdf", size: 96_000),
      ], inBin: [1, 2, 3])

    #expect(page.groups.map(\.folder) == [downloads, screenshots])
    #expect(page.groups.map(\.summary) == ["2 items · \(bytes(1_600_096_000))", "1 item · 4 MB"])
    #expect(page.title == "Today \(clock(now))")
    #expect(
      page.subtitle
        == "\(dayAndDate(now)) · 2 folders · 3 items · \(bytes(1_604_096_000)) · 3 items still in the Bin"
    )
  }

  @Test func leavesTheBinOutOnceNothingIsInIt() {
    let page = state([entry(1, "a.pdf", .delete)], inBin: [])

    #expect(page.subtitle == "\(dayAndDate(now)) · 1 folder · 1 item · 1 kB")
    #expect(page.groups[0].putBackEntryIDs.isEmpty)
  }

  @Test func aLongGroupShowsAFewFilesThenTheRest() {
    let five = state((1...5).map { entry(Int64($0), "f\($0)") }, inBin: []).groups[0]
    let six = state((1...6).map { entry(Int64($0), "f\($0)") }, inBin: []).groups[0]

    #expect(five.shownFiles(isExpanded: false).count == 5)
    #expect(five.more(isExpanded: false) == nil)
    #expect(six.shownFiles(isExpanded: false).map(\.name) == ["f1", "f2", "f3"])
    #expect(six.more(isExpanded: false) == "and 3 more")
    #expect(six.shownFiles(isExpanded: true).count == 6)
    #expect(six.more(isExpanded: true) == nil)
  }
}
