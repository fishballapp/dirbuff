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

/// The clean-up running now: the folder, the item going and how far it has got.
public struct PopoverRun: Sendable, Equatable {
  public var folderID: Int64
  public var folderName: String
  public var path: String
  /// The item going now; nil before the first one and after the last.
  public var current: String?
  /// "3 of 12 items · 1.3 GB"; nil until the run has reported how much there is.
  public var counts: String?
  /// How much of the run's items are done, from 0 to 1.
  public var fraction: Double
}

/// A folder that needs the user: its name and path for the callout's pill, why, and the one fix.
public struct NeedsYou: Sendable, Equatable, Identifiable {
  public var id: Int64
  public var folderName: String
  public var path: String
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
  ///   - reports: What reading each folder found; their `lastRunAt` says when the last clean-up ran.
  ///   - progress: How far the clean-up running now has got.
  public init(
    folders: [FolderState],
    reports: [FolderReport] = [],
    progress: Engine.RunProgress? = nil,
    licence: Licence,
    now: Date,
    calendar: Calendar = .current
  ) {
    // A folder wearing nothing has nothing to say here.
    let listed = folders.filter { !$0.buffs.isEmpty }
    let needsYou = listed.compactMap { callout($0, now: now, calendar: calendar) }
    let clearing = listed.filter { $0.buffs.contains { $0.state == .working } }
    let paused = listed.filter { $0.buffs.contains { $0.state.isPaused } }
    let listedIDs = Set(listed.map(\.id))
    let schedule = schedule(
      lastCleanUp: reports.filter { listedIDs.contains($0.folder.id ?? -1) }.map(\.folder.lastRunAt)
        .max(),
      now: now, calendar: calendar)
    let (headline, subheadline): (String, String?) = {
      if !licence.mayClean { return ("Every buff is paused", pausedReason(licence)) }
      if listed.isEmpty {
        return ("No buffed folders yet", "Right-click a folder in Finder, then DirBuff: Add Buff")
      }
      if !needsYou.isEmpty {
        let others = listed.count > needsYou.count ? "Everything else is fine" : nil
        return (needsYouHeadline(needsYou.count), others)
      }
      // The run stands in for the schedule while a clean-up runs.
      if !clearing.isEmpty { return (clearingHeadline(clearing), nil) }
      if !paused.isEmpty { return (pausedHeadline(paused.count), schedule) }
      return (fineHeadline(listed.count), schedule)
    }()
    self.init(
      headline: headline,
      subheadline: subheadline,
      needsYou: needsYou,
      run: needsYou.isEmpty ? currentRun(clearing, progress: progress) : nil,
      glyph: glyphState(listed, licence: licence),
      foot: licence.line.map(PopoverFoot.init)
    )
  }
}

/// When the clean-ups are: "Last clean-up 37 min ago · next in 23 min", or only the next one
/// before any has run.
private func schedule(lastCleanUp: Date?, now: Date, calendar: Calendar) -> String {
  let next = timeLeft(until: nextCleanUp(after: now, calendar: calendar), now: now)
  guard let lastCleanUp else { return "Next clean-up in \(next)" }
  return "Last clean-up \(timeSince(lastCleanUp, now: now)) ago · next in \(next)"
}

/// The callout for a folder that needs the user: its first buff that does.
private func callout(_ folder: FolderState, now: Date, calendar: Calendar) -> NeedsYou? {
  folder.buffs.lazy.compactMap { row -> NeedsYou? in
    guard case .needsYou(let fix) = row.state else { return nil }
    let (lead, reason) =
      switch fix {
      case .giveAccess:
        ("Can't clear", accessReason(row, lostAt: folder.accessLostAt, now: now))
      // The row's setting says since when it has been missing.
      case .locate: (row.status, row.setting)
      }
    return NeedsYou(
      id: folder.id, folderName: folder.name, path: folder.path, lead: lead, reason: reason,
      fix: fix)
  }.first
}

private func accessReason(_ row: BuffRow, lostAt: Date?, now: Date) -> String {
  guard let lostAt else { return row.status }
  return "\(row.status) \(timeSince(lostAt, now: now)) ago"
}

/// The run on show: the folder the engine reports on, or else the first one clearing, which has
/// reported nothing yet.
private func currentRun(_ clearing: [FolderState], progress: Engine.RunProgress?) -> PopoverRun? {
  let reporting = progress.flatMap { progress in clearing.first { $0.id == progress.folderID } }
  guard let folder = reporting ?? clearing.first else { return nil }
  let report = reporting == nil ? nil : progress
  return PopoverRun(
    folderID: folder.id, folderName: folder.name, path: folder.path,
    current: report?.current,
    counts: report.map {
      "\($0.itemsDone) of \(items($0.itemsTotal)) · \(bytes($0.bytesTotal))"
    },
    fraction: report.map { $0.itemsTotal == 0 ? 0 : $0.fraction } ?? 0)
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

private func pausedHeadline(_ count: Int) -> String {
  count == 1 ? "1 folder is paused" : "\(count) folders are paused"
}

private func fineHeadline(_ count: Int) -> String {
  count == 1 ? "The folder is fine" : "All \(count) folders are fine"
}
