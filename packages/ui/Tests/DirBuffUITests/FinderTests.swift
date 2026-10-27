import AppKit
import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

/// Temporary sandbox folders created under `FileManager.default.temporaryDirectory` for each test.
private struct TestFolders {
  let root: URL
  let plain: URL
  let desktop: URL
  let downloads: URL
  let projects: URL
  let archive: URL

  init() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("dirbuff-finder-\(UUID().uuidString)", isDirectory: true)
    plain = base.appendingPathComponent("Scratch", isDirectory: true)
    desktop = base.appendingPathComponent("Desktop", isDirectory: true)
    downloads = base.appendingPathComponent("Downloads", isDirectory: true)
    projects = base.appendingPathComponent("Projects", isDirectory: true)
    archive = base.appendingPathComponent("Archive", isDirectory: true)
    for folder in [plain, desktop, downloads, projects, archive] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    root = base
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func makeSnapshot(
  _ reports: [FolderReport],
  protected: [URL] = [],
  licence: Licence = .licensed,
  working: Set<Int64> = []
) -> FinderSnapshot {
  let states = FolderState.all(
    reports,
    licence: licence,
    working: working,
    now: now,
    calendar: calendar,
    binName: "Bin",
    home: home
  )
  return FinderSnapshot(
    folders: states,
    licence: licence,
    protectedFolderPaths: protected.map(\.path),
    binName: "Bin"
  )
}

@Suite struct FinderBadges {
  @Test func plainFolderShowsNoBadge() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let snapshot = makeSnapshot([], protected: [folders.desktop])
    #expect(snapshot.badge(for: folders.plain) == nil)
    #expect(snapshot.badge(for: folders.desktop) == nil)
  }

  @Test func buffedFolderAtRestShowsRestingMark() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let snapshot = makeSnapshot([report(1, path: folders.downloads.path)])
    #expect(snapshot.badge(for: folders.downloads) == .atRest)
  }

  @Test func needsYouWorkingAndPausedBadgesFollowFolderState() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let needsYouReport = report(
      1,
      path: folders.projects.path,
      problem: .noAccess,
      accessLostAt: now - 3 * oneDay - 60
    )
    let workingReport = report(
      2,
      path: folders.downloads.path,
      dueNow: [item("a")]
    )
    let pausedReport = report(
      3,
      path: folders.archive.path,
      problem: .unreachable
    )

    let snapshot = makeSnapshot(
      [needsYouReport, workingReport, pausedReport],
      working: [2]
    )

    #expect(snapshot.badge(for: folders.projects) == .needsYou)
    #expect(snapshot.badge(for: folders.downloads) == .working)
    #expect(snapshot.badge(for: folders.archive) == .paused)
  }

  @Test func marksAreHiddenWheneverLicenceDoesNotAllowCleaning() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let downloadsReport = report(1, path: folders.downloads.path)
    let projectsReport = report(2, path: folders.projects.path, problem: .noAccess)
    let turnedOffReport = report(
      3,
      path: folders.archive.path,
      wearsTemporary: false,
      turnedOffByLicence: true
    )

    for inactiveLicence in [Licence.trialEnded, .ended(paidThrough: now), .paused] {
      let snapshot = makeSnapshot(
        [downloadsReport, projectsReport, turnedOffReport],
        licence: inactiveLicence
      )
      #expect(snapshot.badge(for: folders.downloads) == nil)
      #expect(snapshot.badge(for: folders.projects) == nil)
      #expect(snapshot.badge(for: folders.archive) == nil)
      #expect(snapshot.folders.count == 3)
    }

    for activeLicence in [Licence.trial(daysLeft: 5), .licensed, .kept(paidThrough: now)] {
      let snapshot = makeSnapshot([downloadsReport], licence: activeLicence)
      #expect(snapshot.badge(for: folders.downloads) == .atRest)
    }
  }

  @Test func takenOffFolderShowsNoBadge() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let takenOffReport = report(
      1,
      path: folders.downloads.path,
      wearsTemporary: false,
      takenOffAt: now.addingTimeInterval(-600)
    )
    let snapshot = makeSnapshot([takenOffReport])
    #expect(snapshot.badge(for: folders.downloads) == nil)
  }

  @Test func badgeIdentifiersAreDistinctForEachMark() {
    #expect(Set(MarkState.allCases.map(\.badgeIdentifier)).count == MarkState.allCases.count)
  }

  @Test @MainActor func badgeAndMenuImagesRenderAtExpectedSizes() {
    for state in MarkState.allCases {
      let image = Mark.badgeImage(for: state)
      #expect(image.size == NSSize(width: 20, height: 20))
      #expect(!image.isTemplate)
    }
    for buff in Buff.allCases {
      let image = BuffSymbol.menuImage(for: buff)
      #expect(image.size == NSSize(width: 23, height: 16))
      #expect(image.isTemplate)
    }
  }
}

@Suite struct FinderSnapshots {
  @Test func badgeChangesReportAddedChangedAndRemovedMarks() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let before = makeSnapshot([
      report(1, path: folders.downloads.path),
      report(2, path: folders.projects.path),
    ])
    let after = makeSnapshot([
      report(1, path: folders.downloads.path, problem: .noAccess),
      report(3, path: folders.archive.path),
    ])

    let changes = after.badgeChanges(from: before)
    let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0.mark) })
    #expect(byPath[resolvedFinderPath(folders.downloads.path)] == .some(.needsYou))
    #expect(byPath[resolvedFinderPath(folders.projects.path)] == .some(nil))
    #expect(byPath[resolvedFinderPath(folders.archive.path)] == .some(.atRest))
  }

  @Test func equalSnapshotsEncodeToIdenticalSortedKeyBytes() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let snapshot = makeSnapshot(
      [report(1, path: folders.downloads.path)],
      protected: [folders.desktop]
    )
    let first = try #require(snapshot.encoded())
    let second = try #require(FinderSnapshot.decode(first).encoded())
    #expect(first == second)
    #expect(FinderSnapshot.decode(first) == snapshot)
  }
}

@Suite struct FinderMenus {
  @Test func plainFolderOffersAddBuff() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let snapshot = makeSnapshot([], protected: [folders.desktop])
    let menu = snapshot.menu(for: folders.plain)
    #expect(menu.title == "DirBuff: Add Buff")
    #expect(
      menu.items == [
        FinderMenuItem(
          title: "Temporary",
          subtitle: "Things go after 90 days, to the Bin",
          buff: .temporary,
          action: .addTemporary,
          isEnabled: true
        ),
        FinderMenuItem(
          title: "Backup",
          subtitle: "Soon",
          buff: .backup,
          action: nil,
          isEnabled: false
        ),
        .separator,
        FinderMenuItem(
          title: "Organise",
          subtitle: "Soon",
          buff: .organise,
          action: nil,
          isEnabled: false
        ),
        FinderMenuItem(
          title: "Search",
          subtitle: "Soon",
          buff: .search,
          action: nil,
          isEnabled: false
        ),
      ])
  }

  @Test func protectedFolderDisablesTemporaryWithReason() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let snapshot = makeSnapshot([], protected: [folders.desktop])
    let menu = snapshot.menu(for: folders.desktop)
    #expect(menu.title == "DirBuff: Add Buff")
    #expect(
      menu.items.first
        == FinderMenuItem(
          title: "Temporary",
          subtitle: "Desktop is protected. DirBuff never clears it.",
          buff: .temporary,
          action: nil,
          isEnabled: false
        ))
  }

  @Test func buffedFolderListsCapitalisedSettingAndActions() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let downloadsReport = report(
      1,
      path: folders.downloads.path,
      TemporarySettings(maxAgeDays: 14),
      upcoming: [
        (item("a", size: 500_000_000), oneDay),
        (item("b", size: 800_000_000), oneDay + 60),
      ]
    )
    let snapshot = makeSnapshot([downloadsReport], protected: [folders.desktop])
    let menu = snapshot.menu(for: folders.downloads)
    #expect(menu.title == "DirBuff: Buffs")
    #expect(
      menu.items == [
        .sectionHeader("Downloads wears"),
        FinderMenuItem(
          title: "Temporary \u{00b7} Older than 14 days, to the Bin",
          subtitle: "2 items go tomorrow \u{00b7} \(bytes(1_300_000_000))",
          buff: .temporary,
          action: .openFolder,
          isEnabled: true
        ),
        FinderMenuItem(title: "Change\u{2026}", action: .change),
        FinderMenuItem(title: "What Goes Next\u{2026}", action: .whatGoesNext),
        FinderMenuItem(title: "Take Temporary Off", action: .takeTemporaryOff),
        .separator,
        .sectionHeader("Add"),
        FinderMenuItem(
          title: "Backup",
          subtitle: "Soon",
          buff: .backup,
          action: nil,
          isEnabled: false
        ),
        FinderMenuItem(
          title: "Organise",
          subtitle: "Soon",
          buff: .organise,
          action: nil,
          isEnabled: false
        ),
        FinderMenuItem(
          title: "Search",
          subtitle: "Soon",
          buff: .search,
          action: nil,
          isEnabled: false
        ),
        .separator,
        FinderMenuItem(title: "Open in DirBuff", action: .openFolder),
      ])
  }

  @Test func needsYouFolderShowsProblemInBuffRow() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let needsYouReport = report(
      1,
      path: folders.projects.path,
      problem: .noAccess,
      accessLostAt: now - 3 * oneDay - 60
    )
    let snapshot = makeSnapshot([needsYouReport])
    let menu = snapshot.menu(for: folders.projects)
    #expect(menu.title == "DirBuff: Buffs")
    #expect(
      menu.items[1]
        == FinderMenuItem(
          title: "Temporary \u{00b7} Nothing cleared for 3 days",
          subtitle: "macOS took away access",
          buff: .temporary,
          action: .openFolder,
          isEnabled: true
        ))
  }

  @Test func takenOffFolderOffersAddBuffInFinder() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    let takenOffReport = report(
      1,
      path: folders.downloads.path,
      wearsTemporary: false,
      takenOffAt: now.addingTimeInterval(-600)
    )
    let snapshot = makeSnapshot([takenOffReport])
    #expect(snapshot.menu(for: folders.downloads).title == "DirBuff: Add Buff")
  }

  @Test func addBuffItemsStayEnabledWhenLicenceDoesNotAllowCleaning() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    for inactiveLicence in [Licence.trialEnded, .ended(paidThrough: now), .paused] {
      let snapshot = makeSnapshot([], licence: inactiveLicence)
      let menu = snapshot.menu(for: folders.plain)
      #expect(menu.title == "DirBuff: Add Buff")
      #expect(menu.items.first?.isEnabled == true)
      #expect(menu.items.first?.action == .addTemporary)
    }
  }
}

@Suite struct FinderActions {
  @Test func finderActionURLsRoundTrip() throws {
    let folders = try TestFolders()
    defer { folders.cleanUp() }

    for action in FinderAction.allCases {
      let url = try #require(action.url(for: folders.downloads))
      let parsed = try #require(FinderAction.parse(url))
      #expect(parsed.action == action)
      #expect(parsed.folder.path == folders.downloads.path)
    }
  }

  @Test func unknownURLsAreIgnored() throws {
    let unknownHost = try #require(URL(string: "dirbuff://sort?path=/tmp"))
    let missingPath = try #require(URL(string: "dirbuff://folder"))
    #expect(FinderAction.parse(unknownHost) == nil)
    #expect(FinderAction.parse(missingPath) == nil)
  }

  @Test func addingBuffWhenLicenceDoesNotAllowCleaningOpensSettingsInstead() {
    for inactiveLicence in [Licence.trialEnded, .ended(paidThrough: now), .paused] {
      #expect(FinderAction.addTemporary.opensSettings(under: inactiveLicence))
      #expect(!FinderAction.takeTemporaryOff.opensSettings(under: inactiveLicence))
      #expect(!FinderAction.change.opensSettings(under: inactiveLicence))
      #expect(!FinderAction.whatGoesNext.opensSettings(under: inactiveLicence))
      #expect(!FinderAction.openFolder.opensSettings(under: inactiveLicence))
    }

    for activeLicence in [Licence.trial(daysLeft: 5), .licensed, .kept(paidThrough: now)] {
      for action in FinderAction.allCases {
        #expect(!action.opensSettings(under: activeLicence))
      }
    }
  }
}
