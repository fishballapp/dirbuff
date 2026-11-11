import DirBuffKit
import Foundation

/// Restore Folder…: the sheet that offers the dates a Backup folder can be brought back to, then
/// downloads the one chosen into a new folder beside it, as a run.
public struct RestoreFolderState: Sendable, Equatable, Identifiable {
  public enum Step: Sendable, Equatable {
    /// Asking Google Drive which snapshots the backup holds.
    case loading
    /// The backup has a password this Mac's Keychain doesn't hold or no longer matches.
    case password(PasswordAsk)
    /// Choosing a date: `selectedDateID` says which, the newest until the user picks another.
    case choose([RestoreDate])
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
  /// The date the user picked, a choice's `id`; nil until they pick one.
  public var pickedDateID: String?

  /// The date the sheet has selected while a date is chosen: the one picked if the list still
  /// has it, else the newest. Read from the step as it is, so a sheet that opened while the dates
  /// were loading has one selected the moment they arrive.
  public var selectedDateID: String? {
    guard case .choose(let dates) = step else { return nil }
    return pickedDateID.flatMap { picked in dates.contains { $0.id == picked } ? picked : nil }
      ?? dates.first?.id
  }

  public init(folderName: String, folderPath: String, step: Step = .loading) {
    self.folderName = folderName
    self.folderPath = folderPath
    self.step = step
  }

  /// The sheet's heading while a date is chosen.
  var title: String { "Restore \(folderName) as it was" }

  /// The words under it: where the restored folder goes and what is left alone.
  var explanation: String {
    "The folder as it was at that backup comes back as a new folder beside \(folderName). Nothing in \(folderName) is replaced."
  }
}

/// A snapshot to restore, as the date list shows it.
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
