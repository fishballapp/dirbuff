import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private func page(
  _ reports: [FolderReport], id: Int64 = 1, licence: Licence = .licensed,
  working: Set<Int64> = [], progress: Engine.RunProgress? = nil
) -> FolderPageState? {
  let shelf = MainState(
    reports: reports, licence: licence, working: working, progress: progress, now: now,
    calendar: calendar, binName: "Bin", home: home, startupVolumeName: "Macintosh HD",
    protectedPaths: [])
  return FolderPageState(
    folderID: id, reports: reports, shelf: shelf, progress: progress, now: now,
    calendar: calendar, binName: "Bin", home: home)
}

private func card(_ report: FolderReport, working: Bool = false) -> BuffCard? {
  page(
    [report], working: working ? [1] : [],
    progress: working
      ? Engine.RunProgress(
        folderID: 1, itemsDone: 3, itemsTotal: 12, bytesDone: 0, bytesTotal: 1_300,
        current: "a.zip") : nil)?.cards.first
}

// The fixtures' `now` is Thu 15 Oct, 08:00, so the next clean-up is at 09:00.

@Suite struct FolderPageHead {
  @Test func saysWhereTheFolderIsWhatItHoldsAndHowMany() {
    let state = page([report(1, items: [item("a", size: 1_000), item("b", size: 2_000)])])
    #expect(state?.subtitle == "~/Folder1 · \(bytes(3_000)) · 2 items")
  }

  @Test func namesTheDriveForAFolderOnAnotherDisk() {
    let state = page([report(1, path: "/Volumes/T7 Shuttle/Exports", items: [item("a")])])
    #expect(state?.subtitle == "T7 Shuttle · \(bytes(1_000)) · 1 item")
  }

  @Test func saysAnEmptyFolderIsEmpty() {
    #expect(page([report(1)])?.subtitle == "~/Folder1 · Empty")
  }

  @Test func saysWhereAMissingFolderWas() {
    let state = page([report(1, problem: .missing, missingSince: now - oneDay)])
    #expect(state?.subtitle == "Was at ~/Folder1")
    #expect(state?.isMissing == true)
  }

  @Test func isNilForAFolderDirBuffDoesntKnow() {
    #expect(page([report(1)], id: 2) == nil)
  }

  @Test func showsAPlainFolderWithNoCards() {
    let state = page([report(1, wearsTemporary: false)])
    #expect(state?.cards.isEmpty == true)
    #expect(state?.folder.mark == nil)
  }

  @Test func switchesBetweenTheShelfsFoldersNeedsYouFirst() {
    let state = page(
      [
        report(1, name: "Alpha"), report(2, name: "Bravo"),
        report(3, name: "Charlie", problem: .noAccess),
      ], id: 2)
    #expect(state?.switcher.map(\.name) == ["Charlie", "Alpha", "Bravo"])
  }

  @Test func offersOnlyTheBuffsTheFolderDoesntWear() {
    let state = page([report(1)])
    #expect(state?.addBuffItems.contains { $0.buff == .temporary } == false)
    #expect(state?.canAddBuff == true)
    #expect(page([report(1)], licence: .trialEnded)?.canAddBuff == false)
  }
}

@Suite struct TemporaryCardSummary {
  @Test func saysWhatGoesTomorrowAndWhy() {
    let card = card(
      report(
        1, TemporarySettings(maxAgeDays: 14),
        upcoming: [(item("a", size: 1_000), oneDay), (item("b", size: 2_000), oneDay)]))
    #expect(card?.headline == FolderSentence("2 items go tomorrow · \(bytes(3_000))"))
    let detail = card?.detail?.text ?? ""
    #expect(
      detail.hasPrefix(
        "They haven't been added or changed for 14 days. They go at the clean-up at "))
  }

  @Test func saysWhenTheNextThingGoesWhenNothingGoesTomorrow() {
    let card = card(
      report(1, TemporarySettings(maxAgeDays: 30), upcoming: [(item("a"), 5 * oneDay)]))
    #expect(card?.headline == FolderSentence("Nothing goes tomorrow"))
    let detail = card?.detail?.text ?? ""
    #expect(detail.hasPrefix("The next file goes on "))
    #expect(detail.hasSuffix(", when it turns 30 days old."))
  }

  @Test func saysWhenFilesWillGoWhenNothingIsDated() {
    let card = card(report(1, items: [item("a")]))
    #expect(card?.headline == FolderSentence("Nothing goes yet"))
    #expect(
      card?.detail
        == FolderSentence("Files go once they haven't been added or changed for 90 days."))
  }

  @Test func gaugesTheFolderAgainstItsSizeAndNamesItInTheSentence() {
    let card = card(
      report(
        1, TemporarySettings(rule: .size, sizeLimit: 100_000), items: [item("a", size: 47_000)])
    )
    #expect(card?.headline == FolderSentence("Nothing goes yet"))
    #expect(card?.detail?.pill == .before)
    #expect(card?.detail?.text.hasPrefix("holds \(bytes(47_000)). Past \(bytes(100_000)),") == true)
    #expect(card?.gauge?.kind == .level)
    #expect(card?.gauge?.fraction == 0.47)
    #expect(card?.gauge?.figure == "47 of 100 kB")
  }

  @Test func saysAFolderOverItsSizeIsOver() {
    let card = card(
      report(
        1, TemporarySettings(rule: .size, sizeLimit: 1_000),
        items: [item("a", size: 1_500)], dueNow: [item("b", size: 500)]))
    #expect(
      card?.detail?.text.hasPrefix("holds \(bytes(2_000)), over its \(bytes(1_000)).") == true)
    #expect(card?.gauge?.fraction == 1)
  }

  @Test func saysEverythingGoesAtRestart() {
    let card = card(report(1, TemporarySettings(rule: .emptyOnRestart), items: [item("a")]))
    #expect(
      card?.detail
        == FolderSentence("Files here now go at the first clean-up after the Mac restarts."))
  }

  @Test func countsAClearingRunsItems() {
    let card = card(report(1, items: [item("a")]), working: true)
    #expect(card?.headline == FolderSentence("Clearing now"))
    #expect(card?.detail == FolderSentence("Clearing a.zip."))
    #expect(
      card?.gauge
        == Gauge(kind: .progress, fraction: 0.25, figure: "3 of 12 items · \(bytes(1_300))"))
  }

  @Test func namesAMissingFolderAndHowToFindIt() {
    let card = card(report(1, problem: .missing, missingSince: now - oneDay))
    #expect(card?.state == .needsYou(.locate))
    #expect(card?.headline == FolderSentence("Can't find", pill: .after))
    let detail = card?.detail?.text ?? ""
    #expect(detail.hasPrefix("Missing since "))
    #expect(
      detail.hasSuffix(". It may have been deleted or moved. Locate it to turn its buffs back on."))
    #expect(card?.canShowFiles == false)
  }

  @Test func saysWhyALicencePauseStopsIt() {
    let card = page(
      [report(1, wearsTemporary: false, turnedOffByLicence: true)], licence: .trialEnded)?
      .cards.first
    #expect(card?.detail == FolderSentence(PauseReason.licence(.buy).explanation))
    #expect(card?.settings == TemporarySettings())
  }
}

@Suite struct TemporaryCardSetting {
  @Test(arguments: [
    (TemporarySettings(maxAgeDays: 14), "\(home)/F", "Put Back any time from DirBuff or Finder."),
    (
      TemporarySettings(rule: .size, sizeLimit: 1_000, disposal: .delete),
      "/Volumes/T7 Shuttle/Exports",
      "What goes can't be put back, so the space on T7 Shuttle is free at once."
    ),
    (
      TemporarySettings(rule: .automatic), "\(home)/F",
      "What goes can't be put back, so the space on Macintosh HD is free at once."
    ),
    (
      TemporarySettings(rule: .size, sizeLimit: 1_000), "\(home)/F",
      "Put Back any time from DirBuff or Finder. Until the Bin is emptied, they still take space on Macintosh HD."
    ),
  ])
  func saysWhatItMeans(settings: TemporarySettings, path: String, meaning: String) {
    #expect(card(report(1, path: path, settings))?.meaning == meaning)
  }

  @Test(arguments: [
    (
      TemporarySettings(maxAgeDays: 14), TemporarySettings(maxAgeDays: 30), "older than 30 days now"
    ),
    (
      TemporarySettings(), TemporarySettings(rule: .size, sizeLimit: 50_000_000_000),
      "keeps under 50 GB now"
    ),
    (
      TemporarySettings(), TemporarySettings(rule: .emptyOnRestart),
      "empties when the Mac restarts now"
    ),
    (
      TemporarySettings(), TemporarySettings(rule: .automatic),
      "clears when the disk is nearly full now"
    ),
    (TemporarySettings(), TemporarySettings(disposal: .delete), "deletes permanently now"),
    (TemporarySettings(disposal: .delete), TemporarySettings(), "moves files to the Bin now"),
  ])
  func saysWhatChangedForTheToast(
    old: TemporarySettings, new: TemporarySettings, words: String
  ) {
    #expect(settingChange(from: old, to: new, binName: "Bin") == words)
  }
}
