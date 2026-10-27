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
  /// One row per buff it wears, in `Buff` order, and one for a buff just taken off.
  public var buffs: [BuffRow]
  /// When macOS took away DirBuff's access to it, while it's still away.
  public var accessLostAt: Date? = nil
}

/// A buff on a folder: its symbol and name, what it's doing in numbers, and its setting in words.
public struct BuffRow: Sendable, Equatable, Identifiable {
  public var id: Buff { buff }
  public var buff: Buff
  public var state: BuffState
  /// "12 items go tomorrow · 1.3 GB", "macOS took away access", "Off · nothing was moved".
  public var status: String
  /// "Older than 14 days, to the Bin", "A plain folder until tomorrow, 13:37".
  public var setting: String
}

public enum BuffState: Sendable, Equatable {
  case atRest
  /// A clean-up is running: the 4 pt bar.
  case working
  /// The trial or licence ended, or the folder can't be reached: the Paused capsule.
  case paused
  /// The amber row, with its one fix as the default button.
  case needsYou(Fix)
  /// The user took it off; **Put Back** brings it back until this moment.
  case takenOff(putBackUntil: Date)

  /// What it adds to the folder's mark; a buff taken off adds nothing.
  public var mark: MarkState? {
    switch self {
    case .atRest: .atRest
    case .working: .working
    case .paused: .paused
    case .needsYou: .needsYou
    case .takenOff: nil
    }
  }
}

/// The one thing that clears a needs-you.
public enum Fix: Sendable, Equatable {
  /// Opens Privacy & Security, where the user gives DirBuff its access back.
  case giveAccess

  public var title: String {
    switch self {
    case .giveAccess: "Give Access…"
    }
  }
}

extension FolderState {
  /// Every folder that wears a buff or has one that can still be put back, in the reports' order.
  /// A folder whose last buff is gone leaves once the chance to put it back has passed.
  ///
  /// - Parameter working: The folders a clean-up is running in.
  public static func all(
    _ reports: [FolderReport],
    licence: Licence,
    working: Set<Int64> = [],
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
      return FolderState(
        id: id,
        name: report.name,
        path: report.folder.path,
        location: folderLocation(report.folder.path, holding: report.status?.size, home: home),
        mark: buffs.compactMap(\.state.mark).max(),
        buffs: buffs,
        accessLostAt: report.folder.accessLostAt)
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

  // A trial or licence end takes Temporary off but keeps the folder's buff, paused.
  if folder.turnedOffByLicence { return row(.paused, "Nothing goes while paused") }
  guard folder.wearsTemporary else {
    // Nothing is put back while paused: at trial end every buff stays as it was.
    guard licence.mayClean, let until = folder.putBackUntil, now < until else { return nil }
    let time = until.formatted(
      Date.FormatStyle(
        date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
    return row(
      .takenOff(putBackUntil: until), "Off · nothing was moved",
      setting: "A plain folder until \(dayFromNow(until, now: now, calendar: calendar)), \(time)")
  }
  guard licence.mayClean else { return row(.paused, "Nothing goes while paused") }
  switch report.reading {
  case .failure(.noAccess):
    return row(
      .needsYou(.giveAccess), "macOS took away access",
      setting: folder.accessLostAt.map { "Nothing cleared for \(timeSince($0, now: now))" }
        ?? setting)
  case .failure(.unreachable):
    return row(.paused, unreachable(folder.path))
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

/// "T7 Shuttle isn't connected", or for a folder on this Mac, "Can't find the folder".
private func unreachable(_ path: String) -> String {
  volumeName(path).map { "\($0) isn't connected" } ?? "Can't find the folder"
}

/// The drive's name for a path under /Volumes.
private func volumeName(_ path: String) -> String? {
  let parts = path.split(separator: "/")
  guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
  return String(parts[1])
}
