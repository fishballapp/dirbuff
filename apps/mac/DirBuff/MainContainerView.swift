import AppKit
import DirBuffCore
import DirBuffKit
import DirBuffUI
import SwiftUI

/// DirBuff's main window content: binds the app model's state and actions to `MainView`.
struct MainContainerView: View {
  var appModel: AppModel
  @Bindable var windowState: MainWindowState
  var coordinator: WindowCoordinator

  var body: some View {
    TimelineView(CountdownSchedule()) { timeline in
      mainView(now: timeline.date)
    }
  }

  private func mainView(now: Date) -> some View {
    MainView(
      state: appModel.shelfState(now: now),
      selection: $windowState.selection,
      onChooseFolderForBuff: chooseFolderForBuff,
      onAddBuff: addBuff,
      onPutBackBuff: { id, buff in Task { await appModel.putBackBuff(buff, on: id) } },
      onFix: { _, fix in appModel.perform(fix) },
      onSetTemporary: setTemporary,
      onChangeSettings: changeSettings,
      onBuy: appModel.openCheckout,
      onEnterKey: coordinator.openKeyEntry,
      onCheckLicence: { Task { await appModel.checkLicenceNow() } }
    )
  }

  private func chooseFolderForBuff(_ buff: Buff) {
    guard buff == .temporary else { return }
    let panel = NSOpenPanel()
    // The panel holds its delegate weakly.
    let delegate = ProtectedFolderRefusal()
    panel.delegate = delegate
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.message = "Choose a folder to make Temporary"
    panel.prompt = "Add"
    guard withExtendedLifetime(delegate, { panel.runModal() }) == .OK, let url = panel.url else {
      return
    }
    Task {
      await appModel.addFolderWearingTemporary(url)
      windowState.selection = .shelf
    }
  }

  private func addBuff(id: Int64, buff: Buff) {
    guard buff == .temporary else { return }
    setTemporary(id: id, isOn: true)
  }

  private func setTemporary(id: Int64, isOn: Bool) {
    guard let report = appModel.reports.first(where: { $0.folder.id == id }) else { return }
    Task {
      await appModel.setTemporary(report.folder, isOn)
    }
  }

  private func changeSettings(id: Int64, settings: TemporarySettings) {
    guard let report = appModel.reports.first(where: { $0.folder.id == id }) else { return }
    Task {
      await appModel.save(settings, for: report.folder)
    }
  }
}

/// Refuses a protected folder when Add is clicked, so the panel stays open and says why. Disabling
/// it instead would also stop the user opening it, and Downloads is inside the home folder.
private final class ProtectedFolderRefusal: NSObject, NSOpenSavePanelDelegate {
  func panel(_ sender: Any, validate url: URL) throws {
    guard System.isProtected(url) else { return }
    throw NSError(
      domain: "app.fishball.dirbuff", code: 1,
      userInfo: [NSLocalizedDescriptionKey: AppModel.protectedFolderExplanation])
  }
}
