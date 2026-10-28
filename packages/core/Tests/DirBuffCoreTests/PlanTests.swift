import DirBuffCore
import Foundation
import Testing

private let day: TimeInterval = 86_400
private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let folder = URL(fileURLWithPath: "/Users/me/Downloads")

private func item(_ name: String, daysOld: Double?, size: Int64 = 1) -> Item {
  Item(
    url: folder.appendingPathComponent(name),
    freshness: daysOld.map { now.addingTimeInterval(-$0 * day) },
    size: size
  )
}

private func conditions(
  available: Int64 = 50,
  total: Int64 = 100,
  bootedDaysAgo: Double = 10,
  lastRunDaysAgo: Double = 0
) -> RunConditions {
  RunConditions(
    now: now,
    availableCapacity: available,
    totalCapacity: total,
    bootTime: now.addingTimeInterval(-bootedDaysAgo * day),
    lastRunAt: now.addingTimeInterval(-lastRunDaysAgo * day)
  )
}

/// The names `plan` removes, oldest first.
private func removals(
  _ items: [Item],
  _ settings: TemporarySettings,
  _ conditions: RunConditions = conditions(),
  wearsTemporary: Bool = true,
  isProtectedRoot: Bool = false
) -> [String] {
  let snapshot = FolderSnapshot(
    wearsTemporary: wearsTemporary, isProtectedRoot: isProtectedRoot, items: items)
  return plan(snapshot, settings: settings, conditions: conditions).map {
    $0.item.url.lastPathComponent
  }
}

@Suite struct Freshness {
  @Test func isTheLaterOfAddedAndModified() {
    let early = Date(timeIntervalSince1970: 1)
    let late = Date(timeIntervalSince1970: 2)
    #expect(freshness(added: early, modified: late) == late)
    #expect(freshness(added: late, modified: early) == late)
    #expect(freshness(added: nil, modified: early) == early)
    #expect(freshness(added: early, modified: nil) == early)
    #expect(freshness(added: nil, modified: nil) == nil)
  }
}

@Suite struct AgeRule {
  @Test func removesItemsOlderThanTheLimit() {
    let items = [item("old", daysOld: 31), item("edge", daysOld: 30), item("new", daysOld: 1)]
    #expect(removals(items, TemporarySettings(maxAgeDays: 30)) == ["old"])
  }

  @Test func isOffWhileAnotherRuleIsChosen() {
    let settings = TemporarySettings(rule: .size, maxAgeDays: 30, sizeLimit: 100)
    #expect(removals([item("old", daysOld: 999)], settings).isEmpty)
  }
}

@Suite struct SizeRule {
  private let settings = TemporarySettings(rule: .size, sizeLimit: 10)

  @Test func removesOldestFirstUntilTheFolderFits() {
    let items = [
      item("a", daysOld: 3, size: 5), item("b", daysOld: 2, size: 5),
      item("c", daysOld: 1, size: 5),
    ]
    #expect(removals(items, settings) == ["a"])
  }

  @Test func leavesAFolderAtTheLimitAlone() {
    #expect(removals([item("a", daysOld: 3, size: 10)], settings).isEmpty)
  }

  @Test func countsUndatedItemsButNeverRemovesThem() {
    let items = [item("undated", daysOld: nil, size: 20), item("a", daysOld: 3, size: 1)]
    #expect(removals(items, settings) == ["a"])
  }

  @Test func breaksTiesByName() {
    let items = [item("b", daysOld: 3, size: 6), item("a", daysOld: 3, size: 6)]
    #expect(removals(items, settings) == ["a"])
  }
}

@Suite struct AutomaticRule {
  private let settings = TemporarySettings(rule: .automatic)
  private let items = [
    item("a", daysOld: 3, size: 4), item("b", daysOld: 2, size: 4), item("c", daysOld: 1, size: 4),
  ]

  @Test func removesOldestFirstUntilTheVolumeIsBackAtTheThreshold() {
    #expect(removals(items, settings, conditions(available: 5)) == ["a", "b"])
  }

  @Test func leavesAVolumeAtTheThresholdAlone() {
    #expect(removals(items, settings, conditions(available: 10)).isEmpty)
  }

  @Test func alwaysDeletes() {
    let settings = TemporarySettings(rule: .automatic, disposal: .bin)
    #expect(settings.disposal == .delete)
    #expect(removals(items, settings, conditions(available: 5)) == ["a", "b"])
  }
}

@Suite struct EmptyOnRestartRule {
  private let settings = TemporarySettings(rule: .emptyOnRestart)
  private let items = [item("before", daysOld: 2), item("after", daysOld: 0.5)]

  @Test func clearsWhatWasThereBeforeTheReboot() {
    #expect(
      removals(items, settings, conditions(bootedDaysAgo: 1, lastRunDaysAgo: 3))
        == ["before"])
  }

  @Test func doesNothingWhenItAlreadyRanSinceTheReboot() {
    #expect(removals(items, settings, conditions(bootedDaysAgo: 1, lastRunDaysAgo: 0.1)).isEmpty)
  }
}

@Suite struct Plan {
  @Test func namesTheRuleThatChoseEachItem() {
    let snapshot = FolderSnapshot(
      wearsTemporary: true, isProtectedRoot: false, items: [item("big", daysOld: 1, size: 2)])
    let settings = TemporarySettings(rule: .size, sizeLimit: 1)
    #expect(plan(snapshot, settings: settings, conditions: conditions()).map(\.rule) == [.size])
  }

  @Test func isOldestFirst() {
    let items = [item("b", daysOld: 40), item("a", daysOld: 50), item("c", daysOld: 45)]
    let settings = TemporarySettings(maxAgeDays: 30)
    #expect(removals(items, settings) == ["a", "c", "b"])
  }

  @Test(arguments: Rule.allCases) func neverRemovesUndatedItems(rule: Rule) {
    let settings = TemporarySettings(rule: rule, maxAgeDays: 0, sizeLimit: 0)
    let items = [item("undated", daysOld: nil, size: 100)]
    #expect(removals(items, settings, conditions(available: 0, lastRunDaysAgo: 99)).isEmpty)
  }

  @Test func doesNothingOnceTemporaryIsOff() {
    #expect(
      removals([item("old", daysOld: 99)], TemporarySettings(maxAgeDays: 30), wearsTemporary: false)
        .isEmpty)
  }

  @Test func doesNothingOnAProtectedRoot() {
    #expect(
      removals([item("old", daysOld: 99)], TemporarySettings(maxAgeDays: 30), isProtectedRoot: true)
        .isEmpty)
  }
}

@Suite struct ProtectedRoots {
  @Test func coverTheSystemTheHomeFolderAndVolumeRoots() {
    let roots = protectedRoots(
      home: URL(fileURLWithPath: "/Users/me"), volumes: [URL(fileURLWithPath: "/Volumes/Stick")]
    ).map(\.path)
    #expect(
      Set(roots) == [
        "/", "/Applications", "/Library", "/System", "/Users", "/Users/me", "/Users/me/Library",
        "/Volumes/Stick",
      ])
  }
}

@Suite struct Upcoming {
  private let snapshot = FolderSnapshot(
    wearsTemporary: true, isProtectedRoot: false,
    items: [item("new", daysOld: 1), item("undated", daysOld: nil), item("old", daysOld: 25)])

  @Test func datesEachItemByWhenItCrossesTheAgeLimit() {
    let dates = upcoming(snapshot, settings: TemporarySettings(maxAgeDays: 30)).map {
      ($0.item.url.lastPathComponent, $0.date)
    }
    #expect(dates.map(\.0) == ["old", "new"])
    #expect(dates.map(\.1) == [now.addingTimeInterval(5 * day), now.addingTimeInterval(29 * day)])
  }

  @Test func isEmptyWithoutTheAgeRuleOrTemporary() {
    #expect(upcoming(snapshot, settings: TemporarySettings(rule: .size)).isEmpty)
    var notTemporary = snapshot
    notTemporary.wearsTemporary = false
    #expect(upcoming(notTemporary, settings: TemporarySettings()).isEmpty)
  }
}
