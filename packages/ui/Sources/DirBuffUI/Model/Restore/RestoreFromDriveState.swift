import DirBuffKit
import Foundation

/// Restore from Google Drive…: on a new Mac, or after a folder is lost. It lists the Macs'
/// backups in the Drive signed in to, then a backup's folders and their dates, restores one into
/// a place the user chooses, and offers **Keep Backing Up Here**.
public struct RestoreFromDriveState: Sendable, Equatable, Identifiable {
  public enum Step: Sendable, Equatable {
    /// Asking Google Drive which Macs have a backup.
    case loadingMacs
    /// The Macs' backups, this one's among them: `selectedMacID` says which is chosen.
    case macs([BackedUpMac])
    /// A backup with a password: asking for it.
    case password(PasswordAsk)
    /// Reading the backup's snapshots.
    case loadingFolders
    /// The backup's folders and dates; the user picks one and a place.
    case folders(FolderPick)
    /// Downloading one.
    case restoring(RestoreRun)
    /// One or more folders are back; Keep Backing Up Here is the user's to take or leave.
    case restored
    /// Making this Mac continue the backup.
    case keeping
    /// This Mac continues the backup.
    case kept
    /// Why it didn't happen.
    case failed(RestoreProblem)
  }

  public let id = UUID()
  /// The Google account whose Drive is read; nil when DirBuff doesn't know it.
  public var account: String?
  /// The backup opened.
  public var mac: BackedUpMac?
  /// The folders brought back so far.
  public var restored: [RestoredFolder]
  public var step: Step
  /// The Mac the user picked, a `BackedUpMac.id`; nil until they pick one.
  public var pickedMacID: String?

  /// The Mac chosen in the list: the one picked if it is still there, else another Mac's backup
  /// before this Mac's own. Read from the step as it is, so it is there the moment the list is.
  public var selectedMacID: String? {
    guard case .macs(let macs) = step else { return nil }
    return pickedMacID.flatMap { picked in macs.contains { $0.id == picked } ? picked : nil }
      ?? macs.first { !$0.isThisMac }?.id ?? macs.first?.id
  }

  public init(
    account: String? = nil, mac: BackedUpMac? = nil, restored: [RestoredFolder] = [],
    step: Step = .loadingMacs
  ) {
    self.account = account
    self.mac = mac
    self.restored = restored
    self.step = step
  }

  /// The heading of the step the sheet is on.
  var title: String {
    switch step {
    case .loadingMacs, .macs: "Restore from Google Drive"
    case .password(let ask): "\(possessive(ask.macName)) backup has a password"
    case .loadingFolders, .folders: mac.map { "Restore from \(Self.name(of: $0))" } ?? ""
    case .restoring(let run): "Restoring \(run.folderName)"
    case .restored:
      restored.count == 1 ? "\(restored[0].name) is back" : "\(restored.count) folders are back"
    case .keeping: "Taking over the backup…"
    case .kept: "This Mac carries on the backup"
    case .failed(let problem): problem.title
    }
  }

  /// "this Mac" or the Mac's name, for a sentence.
  static func name(of mac: BackedUpMac) -> String { mac.isThisMac ? "this Mac" : mac.name }
}

/// A backup asking for its password.
public struct PasswordAsk: Sendable, Equatable {
  public var macName: String
  /// The last password typed didn't open the backup.
  public var isWrong: Bool
  /// Checking the password typed.
  public var isChecking: Bool
  /// Asked by the backup page for this Mac's own backup, where nothing is taken over: the
  /// password is for that page only.
  public var isForThisMac: Bool

  public init(
    macName: String, isWrong: Bool = false, isChecking: Bool = false,
    isForThisMac: Bool = false
  ) {
    self.macName = macName
    self.isWrong = isWrong
    self.isChecking = isChecking
    self.isForThisMac = isForThisMac
  }

  /// What the prompt says, with the reassurance about where the password goes: nowhere, unless
  /// the backup is taken over.
  public var explanation: String {
    isForThisMac
      ? "This Mac's Keychain doesn't open the backup. Type the password it was protected with. DirBuff uses it until you leave this page and doesn't keep it."
      : "Type the password it was protected with. DirBuff keeps it in this Mac's Keychain only if you choose Keep Backing Up Here afterwards."
  }

  /// Said under the field when the last password was wrong.
  public var wrongSentence: String {
    "That password doesn't open the backup. Check it and try again."
  }
}

/// The folders of a backup and the choice being made among them.
public struct FolderPick: Sendable, Equatable {
  public var folders: [BackedUpFolder]
  /// The chosen folder's series.
  public var selectedSeries: String?
  /// The chosen snapshot's ID; the folder's newest to begin with.
  public var selectedSnapshotID: String?
  /// Where the restored folder goes, a folder's path.
  public var destination: String
  /// `destination` as the sheet shows it: "~/Documents".
  public var destinationName: String

  public init(
    folders: [BackedUpFolder], destination: String, destinationName: String,
    selectedSeries: String? = nil, selectedSnapshotID: String? = nil
  ) {
    self.folders = folders
    self.destination = destination
    self.destinationName = destinationName
    let selected = selectedSeries ?? folders.first?.series
    self.selectedSeries = selected
    self.selectedSnapshotID =
      selectedSnapshotID
      ?? folders.first { $0.series == selected }?.snapshots.max { $0.time < $1.time }?.id
  }

  public var folder: BackedUpFolder? { folders.first { $0.series == selectedSeries } }

  public var snapshot: ResticSnapshot? {
    folder?.snapshots.first { $0.id == selectedSnapshotID }
  }

  /// Chooses a folder, and its newest snapshot.
  public mutating func select(series: String) {
    selectedSeries = series
    selectedSnapshotID = folder?.snapshots.max { $0.time < $1.time }?.id
  }

  /// The dates the chosen folder can be restored to, the newest first.
  public func dates(now: Date, calendar: Calendar = .current) -> [RestoreDate] {
    RestoreDate.list(folder?.snapshots ?? [], now: now, calendar: calendar)
  }

  /// Under a folder's name: where it was, and how many dates it has.
  public static func detail(_ folder: BackedUpFolder, home: String) -> String {
    let path = folder.path.hasPrefix(home) ? "~" + folder.path.dropFirst(home.count) : folder.path
    let count = folder.snapshots.count
    return "\(path) · \(count == 1 ? "1 backup" : "\(count.formatted()) backups")"
  }
}

/// A folder brought back by Restore from Google Drive.
public struct RestoredFolder: Sendable, Equatable, Identifiable {
  /// The new folder's name: "Documents (3 Mar 2027)".
  public var name: String
  public var path: String
  /// The backed-up folder it was restored from.
  public var source: BackedUpFolder
  /// The date of the backup it is as of.
  public var savedAt: Date

  public var id: String { path }

  public init(name: String, path: String, source: BackedUpFolder, savedAt: Date = .distantPast) {
    self.name = name
    self.path = path
    self.source = source
    self.savedAt = savedAt
  }
}

extension RestoreFromDriveState {
  /// The restored folders Keep Backing Up Here carries on: the newest of each series, since a
  /// series is carried on by one folder only.
  public var continuing: [RestoredFolder] {
    Dictionary(grouping: restored, by: \.source.series).values.compactMap {
      $0.max { $0.savedAt < $1.savedAt }
    }
    .sorted { $0.path < $1.path }
  }

  /// The restored folders that stay plain copies: an older restore of a series that a newer one
  /// carries on.
  public var plainCopies: [RestoredFolder] {
    let kept = Set(continuing.map(\.path))
    return restored.filter { !kept.contains($0.path) }
  }

  /// What **Keep Backing Up Here** does, said plainly before it happens.
  public var keepExplanation: [String] {
    guard let mac else { return [] }
    let plain = plainCopies
    let once =
      plain.isEmpty
      ? []
      : [
        "A backed-up folder is carried on by one folder only, and you restored one more than once: \(continuing.map(\.name).joined(separator: ", ")) carries it on, as the newest. \(plain.map(\.name).joined(separator: ", ")) stays a plain copy, and DirBuff doesn't add it."
      ]
    if mac.isThisMac {
      return once + [
        "The folders you restored go on backing up into this Mac's own backup, adding to the history of the folders they came from.",
        "Nothing you restored is uploaded again, because the backup already holds it.",
      ]
    }
    return once + [
      "This Mac takes over \(possessive(mac.name)) backup. The folders you restored go on backing up into it, adding to the history of the folders they came from, so nothing you restored is uploaded again.",
      "That backup is in \(account.map { "\(possessive($0)) Drive" } ?? "this Google Drive"), so that account is the one this Mac backs up to from now on.",
      "From then on this Mac backs up into \(possessive(mac.name)) backup, not into the one it had. That one stays in Google Drive, and nothing backs up into it any more.",
      "Two Macs backing up into one backup get in each other’s way, so switch Backup off on \(mac.name) if it is still in use.",
    ]
  }

  /// Under the heading once folders are back, before the choice.
  public var restoredDetail: String {
    restored.count == 1
      ? "It is a plain copy for now: DirBuff doesn't back it up yet."
      : "They are plain copies for now: DirBuff doesn't back them up yet."
  }

  /// The heading's words for the confirmation.
  public var keptDetail: String {
    guard let mac else { return "" }
    let count = continuing.count
    let folders = count == 1 ? "The restored folder" : "The \(count) restored folders"
    return mac.isThisMac
      ? "\(folders) now back\(count == 1 ? "s" : "") up into this Mac's backup, continuing its history."
      : "\(folders) now back\(count == 1 ? "s" : "") up into \(possessive(mac.name)) backup, continuing its history. Nothing is uploaded again."
  }
}
