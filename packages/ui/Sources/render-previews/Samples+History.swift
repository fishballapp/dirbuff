import DirBuffCore
import DirBuffKit
import DirBuffUI
import Foundation

/// Eighteen runs since the trial began, and the newest one's page: Downloads, Screenshots and
/// Exports at 09:00 on Sun 25 Oct 2026.
extension Samples {
  /// Sun 25 Oct 2026, 10:30 UTC, after the 09:00 run and a Put Back at 10:12.
  static let historyMoment = now.addingTimeInterval(10 * 86_400 + 2.5 * 3_600)

  static let historyCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    calendar.locale = Locale(identifier: "en_GB")
    return calendar
  }()

  /// The window around History: the sample folders on their shelf, in the trial.
  static let historyShelf = MainState(
    reports: reports, licence: .trial(daysLeft: 9), now: historyMoment,
    calendar: historyCalendar, binName: binName)

  /// Downloads where the Mac keeps it, so it draws its own icon; the others don't exist.
  static let historyFolders = [
    HistoryFolder(
      id: 1, name: "Downloads", path: "\(NSHomeDirectory())/Downloads", mark: .atRest),
    HistoryFolder(id: 2, name: "Screenshots", path: "/Users/sample/Screenshots", mark: .atRest),
    HistoryFolder(id: 3, name: "Exports", path: "/Users/sample/Exports", mark: .working),
  ]

  /// The runs before today's, newest first: days back, hour, and what each folder lost, as
  /// folder id: (items, bytes).
  private static let earlierRuns: [(Double, Double, [Int64: (Int, Int64)])] = [
    (1, 18, [2: (1, 4_100_000)]), (1, 14, [1: (3, 210_000_000)]), (1, 10, [2: (2, 18_000_000)]),
    (2, 16, [1: (2, 38_000_000)]), (2, 11, [3: (4, 6_200_000_000)]),
    (2, 9, [1: (5, 790_000_000), 2: (2, 30_000_000)]), (3, 17, [2: (1, 2_200_000)]),
    (3, 14, [1: (2, 41_000_000)]), (3, 10, [1: (3, 1_190_000_000), 2: (2, 10_000_000)]),
    (4, 15, [1: (3, 96_000_000)]), (4, 12, [3: (1, 610_000_000)]),
    (4, 9, [1: (40, 170_000_000), 2: (4, 10_000_000)]), (5, 23, [2: (2, 12_000_000)]),
    (5, 21, [3: (1, 1_400_000_000)]), (5, 19, [1: (6, 330_000_000)]),
    (5, 17, [2: (2, 54_000_000)]), (5, 16, [1: (31, 4_800_000_000)]),
  ]

  private static func historyTime(daysBack: Double, hour: Double) -> Date {
    historyCalendar.startOfDay(for: historyMoment)
      .addingTimeInterval(-daysBack * 86_400 + hour * 3_600)
  }

  /// Today's run, then the earlier ones: eighteen in all.
  static let history = HistoryState(
    [todaysRun]
      + earlierRuns.enumerated().map { index, run in
        RunSummary(
          id: Int64(index + 2), startedAt: historyTime(daysBack: run.0, hour: run.1),
          shares: run.2.mapValues { .init(itemCount: $0.0, size: $0.1) })
      },
    folders: historyFolders, now: historyMoment, calendar: historyCalendar)

  private static func entry(
    _ id: Int64, _ folderID: Int64, _ name: String, _ size: Int64,
    disposal: Disposal = .bin, undoneAt: Date? = nil
  ) -> JournalEntry {
    JournalEntry(
      id: id, runID: 1, folderID: folderID, disposal: disposal, name: name,
      binnedPath: disposal == .bin ? "/Users/sample/.Trash/\(name)" : nil, size: size,
      reasons: [.age], performedAt: historyTime(daysBack: 0, hour: 9), undoneAt: undoneAt)
  }

  private static let runEntries = [
    entry(1, 1, "Screen Recording 9 Oct.mov", 1_600_000_000),
    entry(2, 1, "Sketch-99.dmg", 690_000_000),
    entry(3, 1, "boarding-pass.pdf", 210_000, undoneAt: historyTime(daysBack: 0, hour: 10.2)),
    entry(4, 1, "invoice-sept.pdf", 96_000),
    entry(5, 1, "tickets-export.csv", 12_000),
    entry(6, 2, "Screenshot 2026-10-24 at 22.41.07.png", 4_200_000),
    entry(7, 2, "Screenshot 2026-10-24 at 22.43.50.png", 3_900_000),
    entry(8, 2, "Screenshot 2026-10-24 at 23.02.16.png", 4_600_000),
    entry(9, 2, "Screenshot 2026-10-24 at 23.15.42.png", 3_800_000),
    entry(10, 2, "Screenshot 2026-10-24 at 23.40.09.png", 4_100_000),
    entry(11, 2, "Screenshot 2026-10-25 at 00.12.33.png", 3_400_000),
    entry(12, 3, "Render-v2-final.mov", 1_100_000_000, disposal: .delete),
  ]

  /// Today 09:00, as History sums it from the entries, so its list row and page agree.
  private static let todaysRun = RunSummary(
    id: 1, startedAt: historyTime(daysBack: 0, hour: 9),
    shares: Dictionary(grouping: runEntries, by: \.folderID).mapValues {
      .init(itemCount: $0.count, size: $0.reduce(0) { $0 + $1.size })
    })

  /// Today 09:00: Sketch-99.dmg was emptied from the Bin, boarding-pass.pdf is back, and Exports
  /// deletes permanently.
  static let run = RunState(
    todaysRun, entries: runEntries, folders: historyFolders,
    inBin: [1, 4, 5, 6, 7, 8, 9, 10, 11], now: historyMoment, calendar: historyCalendar,
    binName: binName)
}
