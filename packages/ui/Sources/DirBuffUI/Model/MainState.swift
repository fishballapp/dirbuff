import DirBuffCore
import DirBuffKit
import Foundation

/// The selection in DirBuff's main window: Overview or a specific folder.
public enum MainSelection: Hashable, Sendable {
  case overview
  case folder(Int64)
}

/// A folder listed in the main window sidebar and shown in the detail view.
public struct MainFolder: Sendable, Equatable, Identifiable {
  public var id: Int64
  public var name: String
  public var path: String
  public var isTemporary: Bool
  public var isReadable: Bool
  public var distanceToGoing: String
  public var settings: TemporarySettings
  public var preview: FolderPreview

  public init(
    id: Int64,
    name: String,
    path: String,
    isTemporary: Bool,
    isReadable: Bool,
    distanceToGoing: String,
    settings: TemporarySettings,
    preview: FolderPreview
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.isTemporary = isTemporary
    self.isReadable = isReadable
    self.distanceToGoing = distanceToGoing
    self.settings = settings
    self.preview = preview
  }
}

/// What the main window shows: an overview and a list of folders.
public struct MainState: Sendable, Equatable {
  public var overview: MenuBarState
  public var folders: [MainFolder]
  /// Why no folder can be made Temporary right now; nil while it can.
  public var licenceRefusal: String?
  /// What the button beside that reason is called.
  public var buyTitle: String

  public init(
    overview: MenuBarState, folders: [MainFolder], licenceRefusal: String?,
    buyTitle: String = LicenceLine.Action.buy.title
  ) {
    self.overview = overview
    self.folders = folders
    self.licenceRefusal = licenceRefusal
    self.buyTitle = buyTitle
  }
}

extension MainState {
  public init(
    reports: [FolderReport],
    journal: [JournalEntry],
    freeSpace: Int64,
    isFinderExtensionOff: Bool,
    licence: Licence,
    now: Date,
    calendar: Calendar = .current,
    binName: String = SystemBin.name
  ) {
    self.overview = MenuBarState(
      reports: reports,
      journal: journal,
      freeSpace: freeSpace,
      isFinderExtensionOff: isFinderExtensionOff,
      licence: licence,
      now: now,
      calendar: calendar,
      binName: binName
    )
    self.licenceRefusal = licence.refusal
    self.buyTitle = licence.buyTitle
    self.folders = reports.compactMap { report in
      guard let id = report.folder.id else { return nil }
      let isReadable = report.status != nil
      let isTemporary = report.status?.wearsTemporary == true
      let distance = distanceToGoing(report, licence: licence, now: now, calendar: calendar)
      let preview: FolderPreview = {
        guard let status = report.status else {
          return FolderPreview(headline: "Can't read this folder", forecast: [])
        }
        if !licence.mayClean {
          return FolderPreview(headline: "Cleaning is paused", forecast: [])
        }
        return FolderPreview(
          status,
          settings: report.folder.settings,
          now: now,
          calendar: calendar,
          binName: binName
        )
      }()
      return MainFolder(
        id: id,
        name: report.name,
        path: report.folder.path,
        isTemporary: isTemporary,
        isReadable: isReadable,
        distanceToGoing: distance,
        settings: report.folder.settings,
        preview: preview
      )
    }
  }
}
