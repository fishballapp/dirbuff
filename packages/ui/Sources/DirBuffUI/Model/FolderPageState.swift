import DirBuffCore
import DirBuffKit
import Foundation

/// A folder as its pages read it: its settings and what goes next.
public struct MainFolder: Sendable, Equatable, Identifiable {
  public var id: Int64
  public var name: String
  public var path: String
  public var isTemporary: Bool
  public var isReadable: Bool
  public var settings: TemporarySettings
  public var preview: FolderPreview

  public init(
    id: Int64,
    name: String,
    path: String,
    isTemporary: Bool,
    isReadable: Bool,
    settings: TemporarySettings,
    preview: FolderPreview
  ) {
    self.id = id
    self.name = name
    self.path = path
    self.isTemporary = isTemporary
    self.isReadable = isReadable
    self.settings = settings
    self.preview = preview
  }
}

/// A folder's page: its head, one card per buff it wears, and the folder switcher in its title.
public struct FolderPageState: Sendable, Equatable {
  /// The folder as the shelf shows it: its name, mark and buff rows.
  public var folder: FolderState
  /// Under the name: "~/Downloads · 9.6 GB · 214 items", "T7 Shuttle · 47 GB · 1,204 items", or
  /// "Was at ~/Projects" for a missing folder.
  public var subtitle: String
  /// One card per buff it wears, in `Buff` order.
  public var cards: [BuffCard]
  /// Every folder on the shelf, needs-you first then by name, for the title's switcher.
  public var switcher: [FolderState]
  /// The buffs + Buff can add to it.
  public var addBuffItems: [AddBuffItem]
  /// Whether + Buff can add anything: not while every buff is paused.
  public var canAddBuff: Bool

  /// Whether the folder was deleted, moved to another disk, or moved to the Bin.
  public var isMissing: Bool {
    cards.contains { $0.state == .needsYou(.locate) }
  }
}

/// A buff's card on the folder page: a large status line, one sentence of what happens next, an
/// optional gauge, and its setting.
public struct BuffCard: Sendable, Equatable, Identifiable {
  public var id: Buff { buff }
  public var buff: Buff
  public var state: BuffState
  /// The large status line: "12 items go tomorrow · 1.3 GB", "Can't find [Projects]".
  public var headline: FolderSentence
  /// What happens next: "They haven't been added or changed for 14 days. They go at the clean-up
  /// at 14:00."
  public var detail: FolderSentence?
  public var gauge: Gauge?
  /// What the setting's sentence edits.
  public var settings: TemporarySettings
  /// Under the setting, what it means: "Put Back any time from DirBuff or Finder."
  public var meaning: String
  /// Whether What Goes Next… can list the folder's files: only while it can be read.
  public var canShowFiles: Bool
}

/// Words that may name the folder as a pill, before or after them: "[Exports] holds 47 GB.",
/// "Can't find [Projects]".
public struct FolderSentence: Sendable, Equatable {
  public enum Pill: Sendable, Equatable {
    case none
    case before
    case after
  }

  public var text: String
  public var pill: Pill

  public init(_ text: String, pill: Pill = .none) {
    self.text = text
    self.pill = pill
  }
}

/// A bar under a card's summary, with its figure beside it.
public struct Gauge: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    /// How full the folder is against its limit, in Ink Secondary.
    case level
    /// How far a clean-up has got, in Accent Blue.
    case progress
  }

  public var kind: Kind
  /// From 0 to 1.
  public var fraction: Double
  /// "47 of 50 GB", "3 of 12 items · 1.3 GB".
  public var figure: String
}

/// What a folder page does beyond the shelf's actions. Each starts as a no-op, so previews and
/// tests set only what they use.
public struct FolderPageActions {
  /// Saves the folder's Temporary settings; the change takes effect at once.
  public var changeSettings: (_ folderID: Int64, TemporarySettings) -> Void = { _, _ in }
  /// Switches the page to another folder, from the title's switcher.
  public var openFolder: (_ folderID: Int64) -> Void = { _ in }
  /// What Goes Next…: pushes the folder's files.
  public var showFiles: (_ folderID: Int64) -> Void = { _ in }
  /// ⌘[: back to every folder.
  public var showAllFolders: () -> Void = {}

  public init() {}
}

extension FolderPageState {
  /// The page for `folderID`, or nil when DirBuff no longer knows the folder.
  ///
  /// - Parameters:
  ///   - shelf: The main window's state, which holds every folder's tile and what + Buff offers.
  ///   - progress: How far the clean-up running now has got.
  public init?(
    folderID: Int64,
    reports: [FolderReport],
    shelf: MainState,
    progress: Engine.RunProgress? = nil,
    now: Date,
    calendar: Calendar = .current,
    binName: String = SystemBin.name,
    home: String = NSHomeDirectory()
  ) {
    guard let report = reports.first(where: { $0.folder.id == folderID }) else { return nil }
    // A plain folder opened from Finder has no tile, so it wears nothing here either.
    let folder =
      shelf.shelfFolders.first { $0.id == folderID }
      ?? FolderState(
        id: folderID, name: report.name, path: report.folder.path, location: "", mark: nil,
        buffs: [])
    let words = CardWords(
      folderName: folder.name, volume: volumeName(report.folder.path) ?? shelf.startupVolumeName,
      now: now, calendar: calendar, binName: binName)
    self.folder = folder
    self.subtitle =
      report.problem == .missing
      ? folder.location : pageLocation(report, home: home)
    self.cards = folder.buffs.map { row in
      words.card(
        row, report: report,
        progress: progress.flatMap { $0.folderID == folderID ? $0 : nil })
    }
    self.switcher = shelf.shelfFolders
    self.addBuffItems = shelf.addBuffItems(for: folder)
    self.canAddBuff = shelf.mayClean
  }
}

/// Words for what changed, for the toast after a setting changes: "older than 30 days now",
/// "deletes permanently now".
public func settingChange(
  from old: TemporarySettings, to new: TemporarySettings, binName: String = SystemBin.name
) -> String {
  let ruleChanged =
    old.rule != new.rule
    || (new.rule == .age && old.maxAgeDays != new.maxAgeDays)
    || (new.rule == .size && old.sizeLimit != new.sizeLimit)
  guard ruleChanged else {
    return new.disposal == .delete
      ? "deletes permanently now" : "moves files to the \(binName) now"
  }
  return switch new.rule {
  case .age: "older than \(days(new.maxAgeDays)) now"
  case .size: "keeps under \(bytes(new.sizeLimit)) now"
  case .emptyOnRestart: "empties when the Mac restarts now"
  case .automatic: "clears when the disk is nearly full now"
  }
}

/// Builds a buff's card in one folder's words.
private struct CardWords {
  var folderName: String
  /// The disk the folder is on, which deleting frees space on.
  var volume: String
  var now: Date
  var calendar: Calendar
  var binName: String

  func card(_ row: BuffRow, report: FolderReport, progress: Engine.RunProgress?) -> BuffCard {
    let settings = report.folder.settings
    var card = BuffCard(
      buff: row.buff, state: row.state, headline: FolderSentence(row.status), detail: nil,
      gauge: nil, settings: settings, meaning: meaning(settings),
      canShowFiles: report.status != nil)
    switch row.state {
    case .atRest:
      if let status = report.status { summarise(status, settings: settings, into: &card) }
    case .working:
      card.headline = FolderSentence("Clearing now")
      if let progress {
        card.detail = progress.current.map { FolderSentence("Clearing \($0).") }
        card.gauge = Gauge(
          kind: .progress, fraction: progress.fraction,
          figure:
            "\(progress.itemsDone) of \(items(progress.itemsTotal)) · \(bytes(progress.bytesTotal))"
        )
      }
    case .paused(let reason):
      card.detail = FolderSentence(
        reason.isLicence ? reason.explanation : "Nothing goes until it's connected again.")
    case .needsYou(.giveAccess):
      card.detail = FolderSentence(
        "\(row.setting). Give DirBuff its access back in Privacy & Security.")
    case .needsYou(.locate):
      card.headline = FolderSentence(row.status, pill: .after)
      card.detail = FolderSentence(
        "\(row.setting). It may have been deleted or moved. Locate it to turn its buffs back on.")
    }
    return card
  }

  /// What the folder's rule does next, at rest.
  private func summarise(
    _ status: Engine.FolderStatus, settings: TemporarySettings, into card: inout BuffCard
  ) {
    let cleanUps = status.cleanUps(now: now, calendar: calendar)
    let soonest = soonestTogether(cleanUps)
    let goes = temporaryStatus(status, settings: settings, now: now, calendar: calendar)
    card.headline = FolderSentence(goes)
    switch settings.rule {
    case .age:
      let age = days(settings.maxAgeDays)
      guard let first = soonest.first else {
        card.detail = FolderSentence(
          "Files go once they haven't been added or changed for \(age).")
        return
      }
      if daysAhead(first.at, now: now, calendar: calendar) <= 1 {
        let they = soonest.count == 1 ? "It hasn't" : "They haven't"
        let go = soonest.count == 1 ? "It goes" : "They go"
        card.detail = FolderSentence(
          "\(they) been added or changed for \(age). \(go) \(atCleanUps(soonest.map(\.at)))."
        )
      } else {
        card.headline = FolderSentence("Nothing goes tomorrow")
        let date = day(first.at, now: now, calendar: calendar)
        card.detail = FolderSentence(
          soonest.count == 1
            ? "The next file goes on \(date), when it turns \(age) old."
            : "The next files go on \(date), when they turn \(age) old.")
      }
    case .size:
      let size = status.size
      let limit = settings.sizeLimit
      card.gauge = Gauge(
        kind: .level, fraction: limit > 0 ? min(1, Double(size) / Double(limit)) : 1,
        figure: amountOf(size, limit))
      card.detail = FolderSentence(
        soonest.isEmpty
          ? "holds \(bytes(size)). Past \(bytes(limit)), the oldest files go first, at the next clean-up on the hour."
          : "holds \(bytes(size)), over its \(bytes(limit)). The oldest files go first \(atCleanUps(soonest.map(\.at))), until it fits.",
        pill: .before)
    case .automatic:
      card.detail = FolderSentence(
        soonest.isEmpty
          ? "Once the disk is less than 10% free, the oldest files go first until it has room again."
          : "The disk is nearly full, so the oldest files go first \(atCleanUps(soonest.map(\.at)))."
      )
    case .emptyOnRestart:
      if !soonest.isEmpty {
        card.detail = FolderSentence(
          "The Mac restarted, so what was here before goes \(atCleanUps(soonest.map(\.at))).")
      } else if goes == "Nothing goes yet" {
        card.detail = FolderSentence(
          "Whatever is here when the Mac restarts goes at the first clean-up after.")
      } else {
        card.detail = FolderSentence(
          "Files here now go at the first clean-up after the Mac restarts.")
      }
    }
  }

  /// The items that go first, together, as the status line counts them: today's by the minute,
  /// later ones by the day.
  private func soonestTogether(_ cleanUps: [(item: Item, at: Date)]) -> [(item: Item, at: Date)] {
    guard let soonest = cleanUps.first?.at else { return [] }
    let byMinute = isTodays(cleanUp: soonest, now: now, calendar: calendar)
    return cleanUps.filter {
      byMinute ? $0.at == soonest : calendar.isDate($0.at, inSameDayAs: soonest)
    }
  }

  /// "at the clean-up at 14:00", or "at the clean-ups from 09:00" when they spread over a day.
  private func atCleanUps(_ dates: [Date]) -> String {
    guard let first = dates.min() else { return "at the next clean-up" }
    let time = first.formatted(
      Date.FormatStyle(
        date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
    return Set(dates).count == 1 ? "at the clean-up at \(time)" : "at the clean-ups from \(time)"
  }

  /// What the setting means for what goes.
  private func meaning(_ settings: TemporarySettings) -> String {
    if settings.disposal == .delete {
      return "What goes can't be put back, so the space on \(volume) is free at once."
    }
    let putBack = "Put Back any time from DirBuff or Finder."
    return settings.rule == .size
      ? "\(putBack) Until the \(binName) is emptied, they still take space on \(volume)."
      : putBack
  }
}

extension PauseReason {
  fileprivate var isLicence: Bool {
    if case .licence = self { return true }
    return false
  }
}

/// "47 of 50 GB", with the unit said once when both share it; "800 MB of 10 GB" when they don't.
private func amountOf(_ part: Int64, _ whole: Int64) -> String {
  let (partWords, wholeWords) = (bytes(part), bytes(whole))
  let partUnit = partWords.split(separator: " ").last
  let wholeUnit = wholeWords.split(separator: " ").last
  guard partUnit == wholeUnit, let partUnit else { return "\(partWords) of \(wholeWords)" }
  return "\(partWords.dropLast(partUnit.count + 1)) of \(wholeWords)"
}

/// "~/Downloads · 9.6 GB · 214 items", or "~/Music · Empty"; on another drive, the drive's name
/// first.
private func pageLocation(_ report: FolderReport, home: String) -> String {
  let path = report.folder.path
  let place =
    volumeName(path)
    ?? (path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
  guard let status = report.status else { return place }
  let count = status.items.count
  guard count > 0 else { return "\(place) · Empty" }
  return [place, bytes(status.size), count == 1 ? "1 item" : "\(count.formatted()) items"]
    .joined(separator: " · ")
}

/// The drive's name for a path under /Volumes.
private func volumeName(_ path: String) -> String? {
  let parts = path.split(separator: "/")
  guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
  return String(parts[1])
}
