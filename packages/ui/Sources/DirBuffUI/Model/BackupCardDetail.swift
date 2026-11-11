import DirBuffCore
import DirBuffKit
import Foundation

/// What Backup's card shows besides its status and setting: whose Drive the files go to, what is
/// left out in words (nothing is left out silently), and the folder's latest backups.
public struct BackupCardDetail: Sendable, Equatable {
  /// How many of the latest backups the card lists.
  static let recentCount = 5

  /// The Google account the files go to: "mei.chan@gmail.com"; nil when DirBuff doesn't know it.
  public var account: String?
  /// What every backup of this folder leaves out, a sentence each; fixed.
  public var leftOut: [String]
  /// What the user left out (Show Files' Leave Out), each with **Bring Back**.
  public var userLeftOut: [LeftOutItem]
  /// The latest backups, newest first.
  public var recent: [BackupRunLine]
  /// Whether the card offers Google sign-in: Backup waits for it.
  public var canSignIn: Bool
  /// Whether Show Details… has something to show: a failed backup's error, or what the weekly
  /// check found.
  public var hasDetails: Bool

  public init(
    account: String?, leftOut: [String], userLeftOut: [LeftOutItem] = [],
    recent: [BackupRunLine], canSignIn: Bool, hasDetails: Bool
  ) {
    self.account = account
    self.leftOut = leftOut
    self.userLeftOut = userLeftOut
    self.recent = recent
    self.canSignIn = canSignIn
    self.hasDetails = hasDetails
  }
}

/// Something the user left out of a folder's backups, which **Bring Back** puts in again.
public struct LeftOutItem: Sendable, Equatable, Identifiable {
  public var id: LeaveOut { leaveOut }
  public var leaveOut: LeaveOut
  /// "Taxes/receipts.zip", "Everything called build".
  public var title: String

  public init(_ leaveOut: LeaveOut) {
    self.leaveOut = leaveOut
    title =
      switch leaveOut {
      case .path(let path): path
      case .name(let name): "Everything called \(name)"
      }
  }
}

/// One of a folder's latest backups, on its card: when, then what it did.
public struct BackupRunLine: Sendable, Equatable, Identifiable {
  public var id: Date { startedAt }
  public var startedAt: Date
  public var outcome: BackupAttempt.Outcome
  /// "Today 09:40", "Mon 10:20", "Mon 3 Nov".
  public var when: String
  /// "12 new, 3 changed · 210 MB", "No changes", "Failed: the network is unreachable".
  public var summary: String

  init(_ attempt: BackupAttempt, now: Date, calendar: Calendar) {
    startedAt = attempt.startedAt
    outcome = attempt.outcome
    let time = moment(attempt.startedAt, now: now, calendar: calendar)
    when =
      daysAhead(attempt.startedAt, now: now, calendar: calendar) == 0 ? "Today \(time)" : time
    summary =
      switch attempt.outcome {
      case .running: "Backing up now"
      case .failed: "Failed: \(firstLine(attempt.error ?? "") ?? "no reason given")"
      case .saved: savedSummary(attempt)
      }
  }
}

/// "12 new, 3 changed · 210 MB · 2 files couldn't be read", or "No changes".
private func savedSummary(_ attempt: BackupAttempt) -> String {
  var counts: [String] = []
  if attempt.filesNew > 0 { counts.append("\(attempt.filesNew.formatted()) new") }
  if attempt.filesChanged > 0 { counts.append("\(attempt.filesChanged.formatted()) changed") }
  var parts = counts.isEmpty ? ["No changes"] : [counts.joined(separator: ", ")]
  if attempt.bytesAdded > 0 { parts.append(bytes(attempt.bytesAdded)) }
  if attempt.skippedCount > 0 {
    parts.append(
      attempt.skippedCount == 1
        ? "1 file couldn't be read" : "\(attempt.skippedCount.formatted()) files couldn't be read")
  }
  return parts.joined(separator: " · ")
}

private func firstLine(_ text: String) -> String? {
  text.split(whereSeparator: \.isNewline).first.map {
    String($0).trimmingCharacters(in: .whitespaces)
  }
}

/// Where the Photos library is: it needs Full Disk Access, so no backup reads it yet.
func photosLibraryPath(home: String) -> String {
  home + "/Pictures/Photos Library.photoslibrary"
}

/// What a backup of `folder` leaves out whatever the user does, in words: Home's Library, the
/// Photos library when the folder holds it, and what every backup leaves out (`BackupDefaults`).
func backupLeftOut(folder: String, home: String) -> [String] {
  var lines: [String] = []
  if folder == home {
    lines.append("Library isn't backed up: it holds apps' own files, which they make again.")
  }
  if photosLibraryPath(home: home).hasPrefix(folder + "/") {
    lines.append(
      "Photos library isn't backed up: DirBuff can't read it without Full Disk Access.")
  }
  let rebuilt = BackupDefaults.leftOutNames.filter { $0 != ".DS_Store" }
  lines.append(
    "Left out everywhere: caches, what macOS keeps out of Time Machine, Finder's .DS_Store files, and what a build makes again ("
      + rebuilt.joined(separator: ", ") + ").")
  return lines
}
