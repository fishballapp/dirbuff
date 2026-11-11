import Foundation

/// What a program outside DirBuff (a watchdog, a script) asks of Backup over a
/// `dirbuff://` URL. Unlike a `FinderAction`, it names no folder.
public enum BackupCommand: String, Sendable, Equatable, CaseIterable {
  /// Starts a run of every folder wearing Backup. Nothing happens while Backup is signed out or a
  /// run is going.
  case backUpNow = "back-up-now"
  /// Starts the weekly check now, whether or not it is due.
  case checkNow = "check-now"

  public var url: URL? {
    var components = URLComponents()
    components.scheme = "dirbuff"
    components.host = rawValue
    return components.url
  }

  /// The command a `dirbuff://` URL asks for; nil for any other URL.
  public static func parse(_ url: URL) -> BackupCommand? {
    guard url.scheme == "dirbuff", let host = url.host else { return nil }
    return BackupCommand(rawValue: host)
  }
}
