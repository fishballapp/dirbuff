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

/// The names `plan` removes, oldest first, with each one's reasons.
private func removals(
  _ items: [Item],
  _ settings: TemporarySettings,
  _ conditions: RunConditions = conditions(),
  wearsTemporary: Bool = true,
  isProtectedRoot: Bool = false
) -> [String: Set<Rule>] {
  let snapshot = FolderSnapshot(
    wearsTemporary: wearsTemporary, isProtectedRoot: isProtectedRoot, items: items)
  return Dictionary(
    uniqueKeysWithValues: plan(snapshot, settings: settings, conditions: conditions).map {
      ($0.item.url.lastPathComponent, $0.reasons)
    })
}

private let noRules = TemporarySettings(maxAgeDays: nil)

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
    #expect(removals(items, TemporarySettings(maxAgeDays: 30)) == ["old": [.age]])
  }

  @Test func isOffWithoutALimit() {
    #expect(removals([item("old", daysOld: 999)], noRules).isEmpty)
  }
}

@Suite struct SizeRule {
  private let settings = TemporarySettings(maxAgeDays: nil, sizeLimit: 10)

  @Test func removesOldestFirstUntilTheFolderFits() {
    let items = [
      item("a", daysOld: 3, size: 5), item("b", daysOld: 2, size: 5),
      item("c", daysOld: 1, size: 5),
    ]
    #expect(removals(items, settings) == ["a": [.size]])
  }

  @Test func leavesAFolderAtTheLimitAlone() {
    #expect(removals([item("a", daysOld: 3, size: 10)], settings).isEmpty)
  }

  @Test func countsUndatedItemsButNeverRemovesThem() {
    let items = [item("undated", daysOld: nil, size: 20), item("a", daysOld: 3, size: 1)]
    #expect(removals(items, settings) == ["a": [.size]])
  }

  @Test func breaksTiesByName() {
    let items = [item("b", daysOld: 3, size: 6), item("a", daysOld: 3, size: 6)]
    #expect(removals(items, settings) == ["a": [.size]])
  }
}

@Suite struct AutomaticRule {
  private let settings = TemporarySettings(maxAgeDays: nil, automatic: true, disposal: .delete)
  private let items = [
    item("a", daysOld: 3, size: 4), item("b", daysOld: 2, size: 4), item("c", daysOld: 1, size: 4),
  ]

  @Test func removesOldestFirstUntilTheVolumeIsBackAtTheThreshold() {
    #expect(
      removals(items, settings, conditions(available: 5)) == ["a": [.automatic], "b": [.automatic]])
  }

  @Test func leavesAVolumeAtTheThresholdAlone() {
    #expect(removals(items, settings, conditions(available: 10)).isEmpty)
  }

  @Test func doesNothingInBinMode() {
    var binning = settings
    binning.disposal = .bin
    #expect(removals(items, binning, conditions(available: 0)).isEmpty)
  }

  @Test func countsSpaceOtherRulesFree() {
    var withAge = settings
    withAge.maxAgeDays = 2
    #expect(
      removals(items, withAge, conditions(available: 5))
        == ["a": [.age, .automatic], "b": [.automatic]])
    #expect(removals(items, withAge, conditions(available: 6)) == ["a": [.age, .automatic]])
  }
}

@Suite struct EmptyOnRestartRule {
  private let settings = TemporarySettings(maxAgeDays: nil, emptyOnRestart: true)
  private let items = [item("before", daysOld: 2), item("after", daysOld: 0.5)]

  @Test func clearsWhatWasThereBeforeTheReboot() {
    #expect(
      removals(items, settings, conditions(bootedDaysAgo: 1, lastRunDaysAgo: 3))
        == ["before": [.emptyOnRestart]])
  }

  @Test func doesNothingWhenItAlreadyRanSinceTheReboot() {
    #expect(removals(items, settings, conditions(bootedDaysAgo: 1, lastRunDaysAgo: 0.1)).isEmpty)
  }
}

@Suite struct Plan {
  @Test func listsEveryRuleThatChoseAnItem() {
    let settings = TemporarySettings(maxAgeDays: 30, sizeLimit: 1)
    let items = [item("old", daysOld: 40, size: 1), item("new", daysOld: 1, size: 1)]
    #expect(removals(items, settings) == ["old": [.age, .size]])
  }

  @Test func isOldestFirst() {
    let items = [item("b", daysOld: 40), item("a", daysOld: 50), item("c", daysOld: 45)]
    let snapshot = FolderSnapshot(wearsTemporary: true, isProtectedRoot: false, items: items)
    let settings = TemporarySettings(maxAgeDays: 30)
    let names = plan(snapshot, settings: settings, conditions: conditions()).map {
      $0.item.url.lastPathComponent
    }
    #expect(names == ["a", "c", "b"])
  }

  @Test func neverRemovesUndatedItems() {
    let settings = TemporarySettings(
      maxAgeDays: 0, sizeLimit: 0, automatic: true, emptyOnRestart: true, disposal: .delete)
    let items = [item("undated", daysOld: nil, size: 100)]
    #expect(removals(items, settings, conditions(available: 0, lastRunDaysAgo: 99)).isEmpty)
  }

  @Test func doesNothingOnceTheTagIsGone() {
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
        "/", "/Applications", "/Library", "/System", "/Users", "/Users/me", "/Users/me/Desktop",
        "/Users/me/Documents", "/Users/me/Library", "/Volumes/Stick",
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

  @Test func isEmptyWithoutTheAgeRuleOrTheTag() {
    #expect(upcoming(snapshot, settings: noRules).isEmpty)
    var notTemporary = snapshot
    notTemporary.wearsTemporary = false
    #expect(upcoming(notTemporary, settings: TemporarySettings()).isEmpty)
  }
}
