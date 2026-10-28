import DirBuffCore
import DirBuffKit
import Foundation

/// One folder as every surface shows it: the shelf's tile, the popover's row, the switcher, the
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
}

/// A buff on a folder: its symbol and name, what it's doing in numbers, and its setting in words.
public struct BuffRow: Sendable, Equatable, Identifiable {
  public var id: Buff { buff }
  public var buff: Buff
  public var state: BuffState
  /// "12 items go tomorrow · 1.3 GB", "macOS took away access".
  public var status: String
  /// "Older than 14 days, to the Bin".
  public var setting: String
  /// A folder the status names, drawn as a pill after it: "Can't find [Projects]".
  public var statusFolder: String? = nil
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
    case .paused(.driveUnplugged): .atRest
    case .needsYou: .needsYou
    }
  }
}

extension BuffState {
  public var isPaused: Bool {
    if case .paused = self { return true }
    return false
  }
}

/// Why a buff is paused.
public enum PauseReason: Sendable, Equatable {
  /// The trial or licence stopped every buff; the action is what the licence line offers. The user
  /// must act, so the folder's mark needs them.
  case licence(LicenceLine.Action)
  /// The folder's drive, named, isn't connected. Nothing for the user to do.
  case driveUnplugged(String)
}

/// The one thing that clears a needs-you.
public enum Fix: Sendable, Equatable {
  /// Opens Privacy & Security, where the user gives DirBuff its access back.
  case giveAccess
  /// Asks where a missing folder went. Remove from DirBuff sits beside it.
  case locate

  public var title: String {
    switch self {
    case .giveAccess: "Give Access…"
    case .locate: "Locate…"
    }
  }
}

extension FolderState {
  /// Every folder that wears a buff or has one that can still be put back, in the reports' order.
  /// A folder whose last buff is gone leaves once the chance to put it back has passed.
  ///
  /// - Parameters:
  ///   - working: The folders a clean-up is running in.
  ///   - progress: How far the folder running now has got.
  public static func all(
    _ reports: [FolderReport],
    licence: Licence,
    working: Set<Int64> = [],
    progress: Engine.RunProgress? = nil,
    now: Date,
    calendar: Calendar = .current,
    binName: String = SystemBin.name,
    home: String = NSHomeDirectory()
  ) -> [FolderState] {
    reports.compactMap { report -> FolderState? in
      guard let id = report.folder.id,
        let temporary = temporaryRow(
          report, licence: licence, isWorking: working.contains(id), now: now,
          calendar: calendar, binName: binName)
      else { return nil }
      let buffs = [temporary]
      let isMissing = report.problem == .missing
      return FolderState(
        id: id,
        name: report.name,
        path: report.folder.path,
        location: isMissing
          ? "Was at \(folderLocation(report.folder.path, holding: nil, home: home))"
          : folderLocation(report.folder.path, holding: report.status?.size, home: home),
        mark: buffs.map(\.state.mark).max(),
        buffs: buffs,
        accessLostAt: report.folder.accessLostAt,
        progress: working.contains(id)
          ? progress.flatMap { $0.folderID == id ? $0.fraction : nil } ?? 0 : nil)
    }
  }
}

/// Temporary's row, or nil when the folder doesn't wear it and it can't be put back.
private func temporaryRow(
  _ report: FolderReport,
  licence: Licence,
  isWorking: Bool,
  now: Date,
  calendar: Calendar,
  binName: String
) -> BuffRow? {
  let folder = report.folder
  let setting = temporarySetting(folder.settings, binName: binName)
  func row(_ state: BuffState, _ status: String, setting: String = setting) -> BuffRow {
    BuffRow(buff: .temporary, state: state, status: status, setting: setting)
  }

  let licencePause = BuffState.paused(.licence(licence.line?.action ?? .buy))
  // A trial or licence end takes Temporary off but keeps the folder's buff, paused.
  if folder.turnedOffByLicence { return row(licencePause, "Nothing goes while paused") }
  guard folder.wearsTemporary else { return nil }
  guard licence.mayClean else { return row(licencePause, "Nothing goes while paused") }
  switch report.reading {
  case .failure(.noAccess):
    return row(
      .needsYou(.giveAccess), "macOS took away access",
      setting: folder.accessLostAt.map { "Nothing cleared for \(timeSince($0, now: now))" }
        ?? setting)
  case .failure(.unreachable):
    let drive = volumeName(folder.path) ?? "The drive"
    return row(.paused(.driveUnplugged(drive)), "\(drive) isn't connected")
  case .failure(.missing):
    var missing = row(
      .needsYou(.locate), "Can't find",
      setting: folder.missingSince.map {
        "Missing since \(missingDate($0, calendar: calendar))"
      } ?? "Missing")
    missing.statusFolder = report.name
    return missing
  case .success(let status):
    if isWorking { return row(.working, "Clearing now") }
    return row(
      .atRest, temporaryStatus(status, settings: folder.settings, now: now, calendar: calendar))
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
private func missingDate(_ date: Date, calendar: Calendar) -> String {
  let day = date.formatted(
    Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
      .weekday(.abbreviated).day().month(.abbreviated))
  let time = date.formatted(
    Date.FormatStyle(
      date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
  return "\(day), \(time)"
}

/// The drive's name for a path under /Volumes.
private func volumeName(_ path: String) -> String? {
  let parts = path.split(separator: "/")
  guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
  return String(parts[1])
}
