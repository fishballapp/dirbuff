import DirBuffCore
import DirBuffKit
import Foundation

/// One folder as every surface shows it: the shelf's tile, the sidebar's row, the popover, the
/// Finder mark. Built from reports by `FolderState.all`.
public struct FolderState: Sendable, Equatable, Identifiable {
  public var id: Int64
  public var name: String
  public var path: String
  /// Where it is: "~/Downloads", or on another drive the drive's name and what the folder holds,
  /// "T7 Shuttle · 47 GB".
  public var location: String
  /// Its most urgent buff's state; nil once it wears no buff. Finder shows it only while the
  /// licence lets DirBuff clean: at trial end the marks leave Finder.
  public var mark: MarkState?
  /// One row per buff it wears, in `Buff` order.
  public var buffs: [BuffRow]
  /// When macOS took away DirBuff's access to it, while it's still away.
  public var accessLostAt: Date? = nil
  /// How far a clean-up running in it has got, from 0 to 1; nil while none runs.
  public var progress: Double? = nil
  /// Why DirBuff can't reach it, whatever it wears: a folder that wears nothing can be missing or
  /// on an unplugged drive too.
  public var problem: FolderProblem? = nil
}

/// A buff on a folder: its symbol and name, what it's doing in numbers, and its setting in words.
public struct BuffRow: Sendable, Equatable, Identifiable {
  public var id: Buff { buff }
  public var buff: Buff
  public var state: BuffState
  /// "12 items to clear tomorrow · 1.3 GB", "macOS took away access".
  public var status: String
  /// "Older than 14 days, to the Bin".
  public var setting: String
  /// A folder the status names, drawn as a pill after it: "Can't find [Projects]".
  public var statusFolder: String? = nil
  /// How far its own run has got, from 0 to 1, while it works. Temporary's is the folder's
  /// `progress`; Backup's is here, since the two can run in one folder at once.
  public var progress: Double? = nil
}

public enum BuffState: Sendable, Equatable {
  case atRest
  /// A clean-up is running: the 4 pt bar.
  case working
  /// The trial or licence ended, or the folder's drive isn't connected: the Paused capsule.
  case paused(PauseReason)
  /// The amber row, with its one fix as the default button.
  case needsYou(Fix)

  /// What it adds to the folder's mark.
  public var mark: MarkState {
    switch self {
    case .atRest: .atRest
    case .working: .working
    case .paused(.licence): .needsYou
    case .paused(.driveUnplugged), .paused(.waiting): .atRest
    case .needsYou: .needsYou
    }
  }
}

extension BuffState {
  public var isPaused: Bool {
    if case .paused = self { return true }
    return false
  }

  /// Why the row wears the Paused pill; nil when it doesn't. A folder DirBuff can't find or open
  /// does nothing too, so it wears the pill beside its callout.
  public var pillReason: PillReason? {
    switch self {
    case .atRest, .working, .paused(.waiting): nil
    case .paused(let reason): .paused(reason)
    case .needsYou(.locate): .folderMissing
    case .needsYou(.giveAccess): .accessLost
    case .needsYou: nil
    }
  }

  /// Whether the row waits on something that clears by itself, which the row says in its status
  /// where a Paused capsule would only repeat it.
  public var isWaiting: Bool {
    if case .paused(.waiting) = self { return true }
    return false
  }
}

/// What a Paused pill's tooltip says.
public enum PillReason: Sendable, Equatable {
  case paused(PauseReason)
  /// DirBuff can't find the folder.
  case folderMissing
  /// macOS took away DirBuff's access to the folder.
  case accessLost
}

/// Why a buff is paused.
public enum PauseReason: Sendable, Equatable {
  /// The trial or licence stopped every buff; the action is what the licence line offers. The user
  /// must act, so the folder's mark needs them.
  case licence(LicenceLine.Action)
  /// The folder's drive, named, isn't connected. Nothing for the user to do.
  case driveUnplugged(String)
  /// Nothing is wrong and nothing is to be done: Backup waits for the internet, or for the user to
  /// sign in to Google. The words are the row's status ("Waiting for the internet"), and the row
  /// fades, with the folder's mark at rest.
  case waiting(String)
}

/// The one thing that clears a needs-you.
public enum Fix: Sendable, Equatable {
  /// Opens Privacy & Security, where the user gives DirBuff its access back.
  case giveAccess
  /// Asks where a missing folder went. Remove from DirBuff sits beside it.
  case locate
  /// Backup: opens Google sign-in again.
  case signInAgain
  /// Backup: opens Google One's storage page, where the user frees or buys room.
  case makeRoom
  /// Backup: opens the files the last backup couldn't read, each with why and Leave Out.
  case showFiles
  /// Backup: runs a backup now instead of at the next hour.
  case backUpNow
  /// Backup: puts the backup back from Google Drive's Bin.
  case putBackFromDriveBin
  /// Backup: makes a new backup where the old one was deleted, which loses its history.
  case startAgain
  /// Backup: opens what the weekly check found missing.
  case showDetails

  public var title: String {
    switch self {
    case .giveAccess: "Give Access…"
    case .locate: "Locate…"
    case .signInAgain: "Sign In Again…"
    case .makeRoom: "Make Room…"
    case .showFiles: "Show Files…"
    case .backUpNow: "Back Up Now"
    case .putBackFromDriveBin: "Put Back"
    case .startAgain: "Start Again…"
    case .showDetails: "Show Details…"
    }
  }

  /// Whether every folder that wears the buff fails the same way, because the cause is the Google
  /// account or the one backup in it: the popover names them in one callout.
  public var isSharedByFolders: Bool {
    switch self {
    case .signInAgain, .makeRoom, .putBackFromDriveBin, .startAgain, .showDetails: true
    case .giveAccess, .locate, .showFiles, .backUpNow: false
    }
  }
}

extension FolderState {
  /// Every folder added to DirBuff, in the reports' order, wearing a buff or not. A folder stays
  /// until it is removed from DirBuff, after its last buff is taken off too.
  ///
  /// - Parameters:
  ///   - working: The folders a clean-up is running in.
  ///   - progress: How far the clean-up running now has got.
  ///   - backingUp: The folders a backup is running in.
  ///   - backupProgress: How far the backup running now has got.
  public static func all(
    _ reports: [FolderReport],
    licence: Licence,
    working: Set<Int64> = [],
    progress: RunProgress? = nil,
    backingUp: Set<Int64> = [],
    backupProgress: RunProgress? = nil,
    now: Date,
    calendar: Calendar = .current,
    binName: String = SystemBin.name,
    home: String = NSHomeDirectory()
  ) -> [FolderState] {
    reports.compactMap { report -> FolderState? in
      guard let id = report.folder.id else { return nil }
      let buffs = report.buffs.map {
        $0.row(
          in: report, licence: licence,
          isWorking: ($0.buff == .backup ? backingUp : working).contains(id), now: now,
          calendar: calendar, binName: binName,
          backupProgress: backupProgress.flatMap { $0.folderID == id ? $0 : nil })
      }
      let isMissing = report.problem == .missing
      return FolderState(
        id: id,
        name: report.name,
        path: report.folder.path,
        location: isMissing
          ? "Was at \(folderLocation(report.folder.path, holding: nil, home: home))"
          : folderLocation(report.folder.path, holding: report.temporaryStatus?.size, home: home),
        mark: buffs.map(\.state.mark).max(),
        buffs: buffs,
        accessLostAt: report.folder.accessLostAt,
        progress: working.contains(id)
          ? progress.flatMap { $0.folderID == id ? $0.fraction : nil } ?? 0 : nil,
        problem: report.problem)
    }
  }
}

extension BuffReading {
  /// The buff's row on `report`'s folder, which a licence pause, a folder DirBuff can't find or
  /// read, or a run in progress overrides.
  func row(
    in report: FolderReport,
    licence: Licence,
    isWorking: Bool,
    now: Date,
    calendar: Calendar,
    binName: String,
    backupProgress: RunProgress? = nil
  ) -> BuffRow {
    switch self {
    case .temporary(let wear, let reading):
      temporaryRow(
        wear, reading, in: report, licence: licence, isWorking: isWorking, now: now,
        calendar: calendar, binName: binName)
    case .backup(let wear, let reading):
      backupRow(
        wear, reading, in: report, licence: licence, isWorking: isWorking,
        progress: backupProgress, now: now, calendar: calendar)
    }
  }
}

private func temporaryRow(
  _ wear: Wear<TemporarySettings>,
  _ reading: Result<TemporaryStatus, FolderProblem>?,
  in report: FolderReport,
  licence: Licence,
  isWorking: Bool,
  now: Date,
  calendar: Calendar,
  binName: String
) -> BuffRow {
  let folder = report.folder
  let setting = temporarySetting(wear.settings, binName: binName)
  func row(_ state: BuffState, _ status: String, setting: String = setting) -> BuffRow {
    BuffRow(buff: .temporary, state: state, status: status, setting: setting)
  }

  let licencePause = BuffState.paused(.licence(licence.line?.action ?? .buy))
  // A trial or licence end keeps the folder's buff, paused.
  guard !wear.isPausedByLicence, licence.mayClean else {
    return row(licencePause, "Nothing is cleared while paused")
  }
  switch report.problem {
  case .noAccess:
    return row(
      .needsYou(.giveAccess), "macOS took away access",
      setting: folder.accessLostAt.map { "Nothing cleared for \(timeSince($0, now: now))" }
        ?? setting)
  case .unreachable:
    let drive = volumeName(folder.path) ?? "The drive"
    return row(.paused(.driveUnplugged(drive)), "\(drive) isn't connected")
  case .missing:
    var missing = row(
      .needsYou(.locate), "Can't find",
      setting: folder.missingSince.map {
        "Missing since \(missingDate($0, calendar: calendar))"
      } ?? "Missing")
    missing.statusFolder = report.name
    return missing
  case nil:
    guard case .success(let status)? = reading else {
      // Put on since the folder was last read; the next read counts what it holds.
      return row(.atRest, "Nothing to clear yet")
    }
    if isWorking { return row(.working, "Clearing now") }
    return row(
      .atRest, temporaryStatus(status, settings: wear.settings, now: now, calendar: calendar))
  }
}

/// "~/Downloads"; "T7 Shuttle · 47 GB" for a folder on another drive; the full path anywhere else.
private func folderLocation(_ path: String, holding size: Int64?, home: String) -> String {
  if let volume = volumeName(path) {
    return [volume, size.map(bytes)].compactMap(\.self).joined(separator: " · ")
  }
  if path == home || path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
  return path
}

/// "Thu 22 Oct, 10:20".
func missingDate(_ date: Date, calendar: Calendar) -> String {
  let day = date.formatted(
    Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
      .weekday(.abbreviated).day().month(.abbreviated))
  let time = date.formatted(
    Date.FormatStyle(
      date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
  return "\(day), \(time)"
}

/// The drive's name for a path under /Volumes.
func volumeName(_ path: String) -> String? {
  let parts = path.split(separator: "/")
  guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
  return String(parts[1])
}
