import DirBuffCore
import DirBuffKit
import Foundation
import Testing

@testable import DirBuffUI

private let downloads = WelcomeFolder(name: "Downloads", path: "\(home)/Downloads")

private func status(daysOld: [Double], settings: TemporarySettings) -> Engine.FolderStatus {
  let items = daysOld.map {
    Item(
      url: URL(fileURLWithPath: "\(home)/Downloads/\($0)"),
      freshness: now.addingTimeInterval(-$0 * 86_400), size: 1_000)
  }
  let snapshot = FolderSnapshot(wearsTemporary: true, isProtectedRoot: false, items: items)
  return Engine.FolderStatus(
    url: URL(fileURLWithPath: "\(home)/Downloads"), wearsTemporary: true,
    isProtectedRoot: false, items: items,
    dueNow: plan(
      snapshot, settings: settings,
      conditions: RunConditions(
        now: now, availableCapacity: 1 << 40, totalCapacity: 1 << 41, bootTime: .distantPast,
        lastRunAt: now)),
    upcoming: upcoming(snapshot, settings: settings))
}

@Suite struct WelcomePlacements {
  @Test func saysWhatTheDefaultDoesInNumbers() {
    let settings = TemporarySettings()
    let placement = WelcomePlacement(
      folder: downloads, folderID: 1, settings: settings,
      status: status(daysOld: [88.9, 88.8, 88.7, 20], settings: settings), now: now,
      calendar: calendar, binName: "Bin")
    #expect(placement.setting == "90 days")
    #expect(placement.sentence == "Files older than 90 days go to the Bin; 3 go tomorrow.")
  }

  @Test func saysNothingGoesFromAFolderWithNothingInIt() {
    let settings = TemporarySettings()
    let placement = WelcomePlacement(
      folder: downloads, folderID: 1, settings: settings,
      status: status(daysOld: [], settings: settings), now: now, calendar: calendar,
      binName: "Bin")
    #expect(placement.sentence == "Files older than 90 days go to the Bin; nothing goes yet.")
  }

  @Test func saysOnlyWhatTheSettingDoesForAFolderItCouldntRead() {
    let placement = WelcomePlacement(
      folder: downloads, folderID: 1,
      settings: TemporarySettings(maxAgeDays: 30, disposal: .delete),
      status: nil, now: now, calendar: calendar, binName: "Bin")
    #expect(placement.sentence == "Files older than 30 days are deleted permanently.")
  }

  @Test func countsOneItemAsGoing() {
    let settings = TemporarySettings()
    let placement = WelcomePlacement(
      folder: downloads, folderID: 1, settings: settings,
      status: status(daysOld: [88.9], settings: settings), now: now, calendar: calendar,
      binName: "Bin")
    #expect(placement.sentence.hasSuffix("1 goes tomorrow."))
  }
}

@Suite struct WelcomeWindow {
  private let projects = WelcomeFolder(name: "Projects", path: "\(home)/Projects")

  private func state(
    _ reports: [FolderReport] = [], chosen: WelcomeFolder? = nil,
    otherFolder: WelcomeFolder? = nil, addedHere: Set<WelcomeFolder.ID> = []
  ) -> WelcomeState {
    WelcomeState(
      setup: SetupState(), licence: .trial(daysLeft: 14), folders: [downloads], reports: reports,
      chosen: chosen, otherFolder: otherFolder, addedHere: addedHere, now: now,
      calendar: calendar, binName: "Bin")
  }

  private func wearing(_ path: String, _ settings: TemporarySettings = TemporarySettings())
    -> FolderReport
  {
    report(1, path: path, settings)
  }

  @Test func closesWithLaterUntilABuffIsOn() {
    #expect(state().closeTitle == "Later")
    #expect(!state().isDone)
    #expect(state([wearing(downloads.path)]).closeTitle == "Done")
  }

  @Test func followsTheFoldersSettingsAsTheyChange() {
    let reports = [wearing(downloads.path, TemporarySettings(maxAgeDays: 30))]
    let placement = state(reports, chosen: downloads).chosenPlacement
    #expect(placement?.setting == "30 days")
    #expect(placement?.sentence.hasPrefix("Files older than 30 days go to the Bin") == true)
  }

  @Test func dropsTheTileOnceTheFolderIsPlainAgain() {
    let plain = report(1, path: downloads.path, wearsTemporary: false)
    let state = state([plain], chosen: downloads)
    #expect(state.placement(on: downloads) == nil)
    #expect(state.chosenPlacement == nil)
    #expect(!state.isDone)
  }

  @Test func showsAFolderThatAlreadyWoreTemporaryAsDoneWithNoUndo() {
    let state = state([wearing(downloads.path)], chosen: downloads)
    let placement = state.chosenPlacement
    #expect(placement != nil)
    #expect(placement.map(state.canUndo) == false)
  }

  @Test func offersUndoOnlyForWhatThisWindowPutOn() {
    let state = state([wearing(downloads.path)], chosen: downloads, addedHere: [downloads.id])
    #expect(state.chosenPlacement.map(state.canUndo) == true)
  }

  @Test func showsAFolderOutsideTheUsualOnesInOtherFolder() {
    #expect(state([wearing(projects.path)]).otherPlacement == nil)
    #expect(
      state([wearing(projects.path)], otherFolder: projects).otherPlacement?.folder == projects)
    #expect(state([], otherFolder: projects).otherPlacement == nil)
  }

  @Test func offersTheUsualFoldersAsTilesAlike() {
    let folders = WelcomeState.usualFolders(home: home)
    #expect(folders.map(\.name) == ["Downloads", "Desktop", "Documents"])
    #expect(
      folders.map(\.path) == ["\(home)/Downloads", "\(home)/Desktop", "\(home)/Documents"])
  }

  @Test func showsDesktopAsDoneOnceItWearsTemporaryLikeDownloads() {
    let desktop = WelcomeState.usualFolders(home: home)[1]
    let state = WelcomeState(
      setup: SetupState(), licence: .trial(daysLeft: 14),
      folders: WelcomeState.usualFolders(home: home),
      reports: [wearing(desktop.path)], chosen: desktop, now: now, calendar: calendar,
      binName: "Bin")
    #expect(state.placement(on: desktop)?.setting == "90 days")
    #expect(state.isDone)
  }
}
