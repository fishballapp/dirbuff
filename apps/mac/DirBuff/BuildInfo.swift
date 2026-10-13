import DirBuffCore
import Foundation

/// What this build says about itself, carried into `Info.plist` by the build.
enum BuildInfo {
  /// The version and build this copy is, as Settings shows them: `0.1.3 (2126)`.
  static var version: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info?[kCFBundleVersionKey as String] as? String ?? "unknown"
    return "\(version) (\(build))"
  }

  /// The day this version came out: `release.sh` sets it for a release, and any other build uses
  /// the day it was built. A missing or unreadable value is a broken build, so it stops the app
  /// rather than guessing which updates its licence covers.
  static func releaseDay() throws -> ReleaseDay {
    guard
      let text = Bundle.main.object(forInfoDictionaryKey: "DirBuffReleaseDate") as? String,
      let day = ReleaseDay(text)
    else {
      throw CocoaError(
        .propertyListReadCorrupt, userInfo: ["key": "DirBuffReleaseDate"])
    }
    return day
  }
}
