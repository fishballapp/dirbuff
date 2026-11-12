import DirBuffKit
import Foundation

/// Restore Folder…, from the backup page with a backup chosen: the folder as that backup saved it
/// comes back as a new folder beside it, downloaded as a run the sheet and the popover show.
public struct RestoreFolderState: Sendable, Equatable, Identifiable {
  public enum Step: Sendable, Equatable {
    /// Downloading.
    case restoring(RestoreRun)
    /// Finished: the new folder's name and path.
    case done(name: String, path: String)
    /// Why it didn't happen.
    case failed(RestoreProblem)
  }

  public let id = UUID()
  public var folderName: String
  public var folderPath: String
  public var step: Step

  public init(folderName: String, folderPath: String, step: Step) {
    self.folderName = folderName
    self.folderPath = folderPath
    self.step = step
  }
}

/// A snapshot to restore, as Restore from Google Drive's date list shows it.
public struct RestoreDate: Sendable, Equatable, Identifiable {
  /// The snapshot's ID.
  public var id: String
  /// "Today, 09:12", "Tue 20 Oct, 18:40".
  public var when: String
  /// "Latest backup · 48 GB", "48 GB".
  public var detail: String

  public init(id: String, when: String, detail: String) {
    self.id = id
    self.when = when
    self.detail = detail
  }

  /// One for each of `snapshots`, the newest first.
  public static func list(
    _ snapshots: [ResticSnapshot], now: Date, calendar: Calendar = .current
  ) -> [RestoreDate] {
    snapshots.sorted { $0.time > $1.time }.enumerated().map { index, snapshot in
      let size = snapshot.size.map(bytes)
      return RestoreDate(
        id: snapshot.id, when: versionMoment(snapshot.time, now: now, calendar: calendar),
        detail: [index == 0 ? "Latest backup" : nil, size].compactMap(\.self)
          .joined(separator: " · "))
    }
  }
}
