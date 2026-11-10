import DirBuffCore
import DirBuffKit
import Foundation

/// Backup's one setting in a few words: "Every version, thinning with age", "Versions kept for 30
/// days".
func backupSetting(_ settings: BackupSettings) -> String {
  switch settings.history {
  case .forever: "Every version, thinning with age"
  case .oneYear: "Versions kept for one year"
  case .thirtyDays: "Versions kept for 30 days"
  }
}

/// What the setting means for the backup, under the card's sentence.
func backupMeaning(_ settings: BackupSettings) -> String {
  switch settings.history {
  case .forever:
    "Recent versions are all kept. Older ones thin out with age, down to one a year, for ever."
  case .oneYear:
    "Recent versions are all kept. Older ones thin out with age, and nothing is kept past a year."
  case .thirtyDays: "Every version from the last 30 days is kept, and nothing older."
  }
}

/// How many runs in a row fail before a backup says it is failing.
let failingRunCount = 3
/// How long every run may fail before a backup says it is failing.
let failingDuration: TimeInterval = 3 * 3_600
/// How long a folder may go without a good backup before it says so.
let staleDuration: TimeInterval = 3 * 86_400

extension BackupStatus {
  /// Runs have failed several times in a row, or for hours on end.
  func isFailing(now: Date) -> Bool {
    guard lastError != nil || failedRunsInARow > 0 else { return false }
    if failedRunsInARow >= failingRunCount { return true }
    return failingSince.map { now.timeIntervalSince($0) >= failingDuration } ?? false
  }

  /// No backup has finished for days, whatever the cause.
  func isStale(now: Date) -> Bool {
    now.timeIntervalSince(lastSuccessAt ?? lastRunAt) >= staleDuration
  }

  /// The last error on one line, for the card.
  var lastErrorLine: String? {
    lastError?.split(whereSeparator: \.isNewline).first.map {
      String($0).trimmingCharacters(in: .whitespaces)
    }
  }
}

/// "1 file couldn't be backed up", "3 files couldn't be backed up".
func filesCouldNotBeBackedUp(_ count: Int) -> String {
  count == 1 ? "1 file couldn't be backed up" : "\(count.formatted()) files couldn't be backed up"
}

/// "120 files only in iCloud".
func filesOnlyInICloud(_ count: Int) -> String {
  count == 1 ? "1 file only in iCloud" : "\(count.formatted()) files only in iCloud"
}

/// The time a moment is told by: "09:40" today, "Mon 10:20" within the week, else "Mon 3 Nov".
func moment(_ date: Date, now: Date, calendar: Calendar) -> String {
  let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
  let time = date.formatted(style.hour().minute())
  switch daysAhead(date, now: now, calendar: calendar) {
  case 0: return time
  case -6..<0: return "\(date.formatted(style.weekday(.abbreviated))) \(time)"
  default: return date.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
  }
}

/// "Not backed up since Mon 10:20", or "Never backed up".
func notBackedUpSince(_ status: BackupStatus?, now: Date, calendar: Calendar) -> String? {
  guard let status else { return nil }
  guard let last = status.lastSuccessAt else { return "Never backed up" }
  return "Not backed up since \(moment(last, now: now, calendar: calendar))"
}

/// "1.2 of 3.4 GB": how far a backup has got, from its bytes.
func backedUpOf(_ progress: RunProgress) -> String? {
  progress.bytesTotal > 0 ? amountOf(progress.bytesDone, progress.bytesTotal) : nil
}

extension DriveState.Wait {
  /// The row's status while the Mac waits.
  func words(calendar: Calendar) -> String {
    switch self {
    case .internet: "Waiting for the internet"
    case .wifi: "Waiting for Wi-Fi"
    case .power: "Waiting for power"
    case .lowPowerMode: "Low Power Mode is on"
    case .googleLimit(let resumesAt):
      "Waiting for Google until "
        + resumesAt.formatted(
          Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).hour().minute())
    }
  }

  /// What waiting means, under the card's status line.
  var explanation: String {
    switch self {
    case .internet: "Backups carry on by themselves once the Mac is online again."
    case .wifi:
      "Backups wait for Wi-Fi so they don't use mobile data. They carry on once the Mac joins one."
    case .power: "The battery is below 20%. Backups carry on once the Mac is plugged in."
    case .lowPowerMode: "Backups carry on once Low Power Mode is turned off."
    case .googleLimit:
      "Google caps how much one app uploads in a day. Backups carry on by themselves when it lifts."
    }
  }
}
