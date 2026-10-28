import DirBuffCore
import DirBuffKit
import Foundation

/// What the menu-bar popover shows: the status sentence, a callout for each folder that needs the
/// user (or a bar while something clears), the folders that wear a buff, the licence's foot, and
/// the menu-bar glyph.
public struct PopoverState: Sendable, Equatable {
  /// "1 folder needs you", "All 6 folders are fine".
  public var headline: String
  /// The line under it; nil when there's nothing to add.
  public var subheadline: String?
  /// One callout per folder that needs the user, with its fix.
  public var needsYou: [NeedsYou]
  /// Whether a clean-up is running. Shown as a bar while nothing needs the user.
  public var isClearing: Bool
  /// Whether the licence lets DirBuff clean. While it doesn't, every folder's line reads as paused.
  public var isCleaning: Bool
  /// The folders that wear a buff, in the order they were added. A buff taken off isn't listed.
  public var folders: [FolderState]
  public var glyph: MenuBarGlyphState
  /// The licence line at the foot; nil while the licence is bought and has nothing to say.
  public var foot: PopoverFoot?
}

/// A folder that needs the user: its name and path for the callout's pill, why, and the one fix.
public struct NeedsYou: Sendable, Equatable, Identifiable {
  public var id: Int64
  public var folderName: String
  public var path: String
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
  /// - Parameter folders: Every folder's state as the app reads it at `now` (`FolderState.all`).
  public init(
    folders: [FolderState],
    licence: Licence,
    now: Date,
    calendar: Calendar = .current
  ) {
    let listed = folders
    let needsYou = listed.compactMap { callout($0, now: now) }
    let clearing = listed.filter { $0.buffs.contains { $0.state == .working } }
    let paused = listed.filter { $0.buffs.contains { $0.state.isPaused } }
    let next = nextCleanUp(after: now, calendar: calendar)
    let countdown = "Next clean-up in \(timeLeft(until: next, now: now))"
    let (headline, subheadline): (String, String?) = {
      if !licence.mayClean { return ("Every buff is paused", pausedReason(licence)) }
      if listed.isEmpty {
        return ("No buffed folders yet", "Right-click a folder in Finder, then DirBuff: Add Buff")
      }
      if !needsYou.isEmpty {
        let others = listed.count > needsYou.count ? "Everything else is fine" : nil
        return (needsYouHeadline(needsYou.count), others)
      }
      // The bar stands in for the countdown while a clean-up runs.
      if !clearing.isEmpty { return (clearingHeadline(clearing), nil) }
      if !paused.isEmpty { return (pausedHeadline(paused.count), countdown) }
      return (fineHeadline(listed.count), countdown)
    }()
    self.init(
      headline: headline,
      subheadline: subheadline,
      needsYou: needsYou,
      isClearing: !clearing.isEmpty,
      isCleaning: licence.mayClean,
      folders: listed,
      glyph: glyphState(listed, licence: licence),
      foot: licence.line.map(PopoverFoot.init)
    )
  }
}

/// The callout for a folder that needs the user: its first buff that does.
private func callout(_ folder: FolderState, now: Date) -> NeedsYou? {
  folder.buffs.lazy.compactMap { row -> NeedsYou? in
    guard case .needsYou(let fix) = row.state else { return nil }
    return NeedsYou(
      id: folder.id, folderName: folder.name, path: folder.path,
      reason: reason(row, lostAt: folder.accessLostAt, now: now), fix: fix)
  }.first
}

private func reason(_ row: BuffRow, lostAt: Date?, now: Date) -> String {
  guard let lostAt else { return row.status }
  return "\(row.status) \(timeSince(lostAt, now: now)) ago"
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
