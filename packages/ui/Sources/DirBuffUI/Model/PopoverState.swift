import DirBuffCore
import DirBuffKit
import Foundation

/// What the menu-bar popover shows: the status sentence with the clean-up schedule under it, a
/// callout for each folder that needs the user (or the clean-up running now), the licence's foot,
/// and the menu-bar glyph. The folders themselves live in the main window.
public struct PopoverState: Sendable, Equatable {
  /// "1 folder needs you", "All 6 folders are fine".
  public var headline: String
  /// The line under it; nil when there's nothing to add.
  public var subheadline: String?
  /// One callout per folder that needs the user, with its fix.
  public var needsYou: [NeedsYou]
  /// The clean-up running now, which takes the top while nothing needs the user.
  public var run: PopoverRun?
  public var glyph: MenuBarGlyphState
  /// The licence line at the foot; nil while the licence is bought and has nothing to say.
  public var foot: PopoverFoot?
}

/// The clean-up or backup running now: the folder, the item going and how far it has got.
public struct PopoverRun: Sendable, Equatable {
  /// The buff whose run it is: Temporary clears, Backup backs up.
  public var buff: Buff
  public var folderID: Int64
  public var folderName: String
  public var path: String
  /// The item going now; nil before the first one and after the last.
  public var current: String?
  /// "3 of 12 items · 1.3 GB", or a backup's "1.2 of 3.4 GB"; nil until the run has reported how
  /// much there is.
  public var counts: String?
  /// How much of the run's items are done, from 0 to 1.
  public var fraction: Double
  /// A restore (Backup's, in the other direction) rather than a backup.
  public var isRestoring = false
}

/// A folder that needs the user: its name and path for the callout's pill, why, and the one fix.
/// When several folders fail for one cause (the Google account, Drive full), they share one
/// callout, which names the first and counts the rest.
public struct NeedsYou: Sendable, Equatable, Identifiable {
  /// The folder named (the first, when several share the callout).
  public var id: Int64
  public var folderName: String
  public var path: String
  /// How many more folders share the callout, "and 2 more"; 0 for a folder on its own.
  public var otherFolders: Int = 0
  /// What the headline says before the folder's pill: "Can't clear", "Can't find".
  public var lead: String
  /// "macOS took away access 3 days ago".
  public var reason: String
  public var fix: Fix
}

/// The licence line at the popover's foot, and the button that acts on it.
public struct PopoverFoot: Sendable, Equatable {
  /// The bold start of the line: "Trial", "Trial ended".
  public var lead: String
  /// What follows it: " · 9 days left".
  public var rest: String
  /// "Buy…", or "Renew…" once the licence has ended.
  public var buttonTitle: String
  /// Whether the button leads to a purchase, which a licence key goes with.
  public var isPurchase: Bool
  /// Whether DirBuff isn't cleaning, so the button is the default one.
  public var isWarning: Bool

  init(_ line: LicenceLine) {
    let lead = line.text.range(of: " · ").map { String(line.text[..<$0.lowerBound]) } ?? line.text
    self.lead = lead
    rest = String(line.text.dropFirst(lead.count))
    isPurchase = line.action.isPurchase
    isWarning = line.isWarning
    buttonTitle =
      switch line.action {
      case .buy: "Buy…"
      case .renew: "Renew…"
      case .checkNow: LicenceLine.Action.checkNow.title
      }
  }
}

extension PopoverState {
  /// - Parameters:
  ///   - folders: Every folder's state as the app reads it at `now` (`FolderState.all`).
  ///   - scheduleLines: When each worn buff runs (`scheduleLines(_:now:)`).
  ///   - progress: How far the clean-up running now has got.
  ///   - backupProgress: How far the backup running now has got.
  ///   - restore: The restore under way, which a clean-up or backup gives the top to.
  public init(
    folders: [FolderState],
    scheduleLines: [String] = [],
    progress: RunProgress? = nil,
    backupProgress: RunProgress? = nil,
    restore: RestoreRun? = nil,
    licence: Licence,
    now: Date,
    calendar: Calendar = .current
  ) {
    // A folder wearing nothing has nothing to say here.
    let listed = folders.filter { !$0.buffs.isEmpty }
    let needing = listed.compactMap { needingYou($0, now: now) }
    let needsYou = callouts(needing)
    let clearing = listed.filter {
      $0.buffs.contains { $0.buff == .temporary && $0.state == .working }
    }
    let backingUp = listed.filter {
      $0.buffs.contains { $0.buff == .backup && $0.state == .working }
    }
    // A buff that waits (for the internet, for sign-in) is not a pause worth a headline.
    let paused = listed.filter {
      $0.buffs.contains { $0.state.isPaused && !$0.state.isWaiting }
    }
    let schedule = scheduleLines.isEmpty ? nil : scheduleLines.joined(separator: "\n")
    let (headline, subheadline): (String, String?) = {
      if !licence.mayClean { return ("Every buff is paused", pausedReason(licence)) }
      // A new Mac restoring has no buffed folder yet.
      if let restore, needing.isEmpty { return ("Restoring \(restore.folderName)", nil) }
      if listed.isEmpty {
        return ("No buffed folders yet", "Right-click a folder in Finder, then DirBuff: Add Buff")
      }
      if !needing.isEmpty {
        let others = listed.count > needing.count ? "Everything else is fine" : nil
        return (needsYouHeadline(needing.count), others)
      }
      // The run stands in for the schedule while a clean-up or backup runs.
      if !clearing.isEmpty { return (clearingHeadline(clearing), nil) }
      if !backingUp.isEmpty { return (backingUpHeadline(backingUp), nil) }
      if !paused.isEmpty { return (pausedHeadline(paused.count), schedule) }
      return (fineHeadline(listed.count), schedule)
    }()
    self.init(
      headline: headline,
      subheadline: subheadline,
      needsYou: needsYou,
      run: needsYou.isEmpty
        ? restore.map(restoreRun)
          ?? currentRun(clearing, progress: progress)
          ?? currentBackup(backingUp, progress: backupProgress)
        : nil,
      glyph: glyphState(listed, licence: licence),
      foot: licence.line.map(PopoverFoot.init)
    )
  }
}

/// The popover's line for each buff some folder wears, in `Buff` order: "Last clean-up 37 min ago ·
/// next in 23 min", "Last backup 4 min ago".
public func scheduleLines(
  _ reports: [FolderReport], now: Date, calendar: Calendar = .current
) -> [String] {
  let cleanUps = reports.compactMap(\.temporaryWear?.lastRunAt).max().map {
    let next = timeLeft(until: nextCleanUp(after: now, calendar: calendar), now: now)
    return "Last clean-up \(timeSince($0, now: now)) ago · next in \(next)"
  }
  return [cleanUps, backupLine(reports, now: now, calendar: calendar)].compactMap(\.self)
}

/// Backup's line: when it last backed up, or what it waits for. Nil when no folder wears it.
private func backupLine(_ reports: [FolderReport], now: Date, calendar: Calendar) -> String? {
  let wearers = reports.filter { $0.backupWear != nil }
  guard let drive = wearers.first?.drive else { return nil }
  let last = wearers.compactMap { $0.backupStatus?.lastSuccessAt }.max()
  let lastBackup = last.map { "Last backup \(timeSince($0, now: now)) ago" }
  switch drive {
  case .notSignedIn: return "Waiting for Google sign-in"
  case .waiting(let wait):
    return [wait.words(calendar: calendar), lastBackup.map(lowercasingFirst)]
      .compactMap(\.self).joined(separator: " · ")
  case .ready, .signedOut, .otherAccount, .full, .backupGone, .backupInBin, .partMissing:
    return lastBackup ?? "No backup yet"
  }
}

/// The callout for a folder that needs the user: its first buff that does.
private func needingYou(_ folder: FolderState, now: Date) -> NeedsYou? {
  folder.buffs.lazy.compactMap { row -> NeedsYou? in
    guard case .needsYou(let fix) = row.state else { return nil }
    let lead = row.buff == .backup ? "Can't back up" : "Can't clear"
    let (headline, reason) =
      switch fix {
      case .giveAccess: (lead, accessReason(row, lostAt: folder.accessLostAt, now: now))
      // The row's setting says since when it has been missing.
      case .locate: (row.status, row.setting)
      case .signInAgain, .chooseAccount, .makeRoom, .showFiles, .backUpNow, .putBackFromDriveBin,
        .startAgain,
        .showDetails:
        (lead, row.status)
      }
    return NeedsYou(
      id: folder.id, folderName: folder.name, path: folder.path, lead: headline, reason: reason,
      fix: fix)
  }.first
}

/// One callout for the folders that fail for a cause they share (the account, Drive full), and
/// one for each other folder. A shared callout takes the place of its first folder's.
private func callouts(_ needing: [NeedsYou]) -> [NeedsYou] {
  var result: [NeedsYou] = []
  for item in needing {
    guard item.fix.isSharedByFolders,
      let first = result.firstIndex(where: { $0.fix == item.fix && $0.reason == item.reason })
    else {
      result.append(item)
      continue
    }
    result[first].otherFolders += 1
  }
  return result
}

private func accessReason(_ row: BuffRow, lostAt: Date?, now: Date) -> String {
  guard let lostAt else { return row.status }
  return "\(row.status) \(timeSince(lostAt, now: now)) ago"
}

/// The run on show: the folder the engine reports on, or else the first one clearing, which has
/// reported nothing yet.
private func currentRun(_ clearing: [FolderState], progress: RunProgress?) -> PopoverRun? {
  let reporting = progress.flatMap { progress in clearing.first { $0.id == progress.folderID } }
  guard let folder = reporting ?? clearing.first else { return nil }
  let report = reporting == nil ? nil : progress
  return PopoverRun(
    buff: .temporary, folderID: folder.id, folderName: folder.name, path: folder.path,
    current: report?.current,
    counts: report.map {
      "\($0.itemsDone) of \(items($0.itemsTotal)) · \(bytes($0.bytesTotal))"
    },
    fraction: report.map { $0.itemsTotal == 0 ? 0 : $0.fraction } ?? 0)
}

/// The restore on show: its bytes are the measure, as a backup's are.
private func restoreRun(_ restore: RestoreRun) -> PopoverRun {
  PopoverRun(
    buff: .backup, folderID: 0, folderName: restore.folderName, path: restore.path, current: nil,
    counts: restore.counts, fraction: restore.fraction, isRestoring: true)
}

/// The backup on show, the same way: its bytes are the measure, "1.2 of 3.4 GB".
private func currentBackup(_ backingUp: [FolderState], progress: RunProgress?) -> PopoverRun? {
  let reporting = progress.flatMap { progress in backingUp.first { $0.id == progress.folderID } }
  guard let folder = reporting ?? backingUp.first else { return nil }
  let report = reporting == nil ? nil : progress
  return PopoverRun(
    buff: .backup, folderID: folder.id, folderName: folder.name, path: folder.path,
    current: report?.current,
    counts: report.flatMap(backedUpOf),
    fraction: report.map {
      $0.bytesTotal == 0 ? 0 : min(1, Double($0.bytesDone) / Double($0.bytesTotal))
    }
      ?? 0)
}

/// While the licence stops cleaning, the glyph is the needs-you one. A folder whose drive isn't
/// connected is at rest, so it doesn't count.
private func glyphState(_ folders: [FolderState], licence: Licence) -> MenuBarGlyphState {
  guard licence.mayClean else { return .needsYou }
  switch folders.compactMap(\.mark).max() {
  case .needsYou: return .needsYou
  case .working: return .working
  case .atRest, nil: return .atRest
  }
}

/// Why cleaning has stopped, under "Every buff is paused".
private func pausedReason(_ licence: Licence) -> String? {
  switch licence {
  case .trialEnded: "Your trial has ended"
  case .ended: "Your licence ended before this version came out"
  case .paused: "DirBuff couldn't check your licence"
  case .trial, .licensed, .kept: nil
  }
}

private func needsYouHeadline(_ count: Int) -> String {
  count == 1 ? "1 folder needs you" : "\(count) folders need you"
}

private func clearingHeadline(_ folders: [FolderState]) -> String {
  guard let only = folders.first, folders.count == 1 else {
    return "Clearing \(folders.count) folders"
  }
  return "Clearing \(only.name)"
}

private func backingUpHeadline(_ folders: [FolderState]) -> String {
  guard let only = folders.first, folders.count == 1 else {
    return "Backing up \(folders.count) folders"
  }
  return "Backing up \(only.name)"
}

private func pausedHeadline(_ count: Int) -> String {
  count == 1 ? "1 folder is paused" : "\(count) folders are paused"
}

private func fineHeadline(_ count: Int) -> String {
  count == 1 ? "The folder is fine" : "All \(count) folders are fine"
}
