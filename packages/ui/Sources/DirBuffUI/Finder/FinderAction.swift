import DirBuffCore
import Foundation

/// What a right-click item in Finder asks the app to do on the target folder.
public enum FinderAction: String, Sendable, Equatable, CaseIterable {
  /// Adds the folder if needed and puts Temporary on with its default settings.
  case addTemporary = "add-temporary"
  /// Takes Temporary off, forgetting its settings; the folder stays, wearing nothing.
  case takeTemporaryOff = "take-temporary-off"
  /// Opens the folder in DirBuff to change its buff settings.
  case change = "change"
  /// Opens the folder in DirBuff to see what is cleared next.
  case whatsClearedNext = "what-goes-next"
  /// Opens the folder in DirBuff.
  case openFolder = "folder"

  /// Builds the `dirbuff://` handoff URL for `folder`.
  public func url(for folder: URL) -> URL? {
    var components = URLComponents()
    components.scheme = "dirbuff"
    components.host = rawValue
    components.queryItems = [URLQueryItem(name: "path", value: folder.path)]
    return components.url
  }

  /// Parses a `dirbuff://` handoff URL into its action and target folder URL.
  public static func parse(_ url: URL) -> (action: FinderAction, folder: URL)? {
    guard url.scheme == "dirbuff",
      let host = url.host,
      let action = FinderAction(rawValue: host),
      let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "path" })?.value,
      !path.isEmpty
    else { return nil }
    return (action, URL(fileURLWithPath: path))
  }

  /// Whether choosing this item while `licence` is in effect opens DirBuff's Settings window
  /// instead of acting on the folder. Adding a buff when the licence doesn't allow cleaning adds
  /// nothing and brings Settings to the front, where the Licence section is at the top.
  public func opensSettings(under licence: Licence) -> Bool {
    switch self {
    case .addTemporary:
      !licence.mayClean
    case .takeTemporaryOff, .change, .whatsClearedNext, .openFolder:
      false
    }
  }
}
