import DirBuffCore
import DirBuffKit
import DirBuffUI
import SwiftUI

extension Samples {
  static let utc = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
  }()

  /// The usual folders on the Mac drawing the previews, so their icons are Finder's own.
  static let welcomeFolders = WelcomeState.usualFolders()

  static func setup(
    isExtensionEnabled: Bool = true, isOpenAtLogin: Bool = true,
    isNotificationsEnabled: Bool = false
  ) -> SetupState {
    SetupState(
      isExtensionEnabled: isExtensionEnabled, isOpenAtLogin: isOpenAtLogin,
      isOpenAtLoginRequiresApproval: false, isNotificationsEnabled: isNotificationsEnabled)
  }

  /// Downloads as the app has it, wearing Temporary with `settings`: three items turn old enough
  /// tomorrow under the default.
  static func welcomeDownloadsReport(_ settings: TemporarySettings = TemporarySettings())
    -> FolderReport
  {
    let path =
      (try? canonicalPath(of: URL(fileURLWithPath: welcomeFolders[0].path)))
      ?? welcomeFolders[0].path
    let items = [88.9, 88.8, 88.7, 20].map { daysOld in
      Item(
        url: URL(fileURLWithPath: "\(path)/item-\(daysOld)"),
        freshness: now.addingTimeInterval(-daysOld * 86_400), size: 40_000_000)
    }
    let snapshot = FolderSnapshot(wearsTemporary: true, isProtectedRoot: false, items: items)
    let status = Engine.FolderStatus(
      url: URL(fileURLWithPath: path), wearsTemporary: true, isProtectedRoot: false, items: items,
      dueNow: plan(
        snapshot, settings: settings,
        conditions: RunConditions(
          now: shownAt, availableCapacity: 120_000_000_000, totalCapacity: 500_000_000_000,
          bootTime: now.addingTimeInterval(-3 * 86_400), lastRunAt: now)),
      upcoming: upcoming(snapshot, settings: settings))
    return FolderReport(
      folder: Folder(
        id: 1, bookmark: Data(), path: path, settings: settings, wearsTemporary: true,
        createdAt: now, lastRunAt: now),
      reading: .success(status))
  }

  /// A stand-in for the app icon, which a command-line tool has no bundle to read: the blue
  /// folder with the arm in white, on the icon's white tile.
  @MainActor
  static var appIcon: Image {
    let renderer = ImageRenderer(content: AppIconStandIn().frame(width: 64, height: 64))
    renderer.scale = 2
    return Image(nsImage: renderer.nsImage ?? NSImage())
  }
}

private struct AppIconStandIn: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 14)
        .fill(.white)
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
      ZStack {
        RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.08, green: 0.40, blue: 0.81))
          .frame(width: 38, height: 30).offset(y: -2)
        RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.18, green: 0.56, blue: 0.94))
          .frame(width: 40, height: 24).offset(y: 5)
        Arm().fill(.white).frame(width: 22, height: 22).offset(y: 5)
      }
    }
    .padding(2)
  }
}
