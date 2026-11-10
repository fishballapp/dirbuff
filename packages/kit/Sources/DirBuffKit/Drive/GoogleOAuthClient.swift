import Foundation

/// The app's identity at Google: the OAuth client of type "Desktop app". Google says a desktop
/// client's secret can't be kept secret and accepts it shipped in the binary, but it still comes
/// from the build, never from the source.
public struct GoogleOAuthClient: Sendable, Equatable {
  public var id: String
  public var secret: String

  /// A build made before the client exists carries neither; sign-in says so instead of failing.
  public var isConfigured: Bool { !id.isEmpty && !secret.isEmpty }

  public init(id: String, secret: String) {
    self.id = id
    self.secret = secret
  }

  /// The build settings `DIRBUFF_GOOGLE_CLIENT_ID` and `DIRBUFF_GOOGLE_CLIENT_SECRET`, which
  /// `Info.plist` carries into the app.
  public static func fromInfoPlist(_ bundle: Bundle = .main) -> GoogleOAuthClient {
    func value(_ key: String) -> String {
      (bundle.object(forInfoDictionaryKey: key) as? String) ?? ""
    }
    return GoogleOAuthClient(
      id: value("DirBuffGoogleClientID"), secret: value("DirBuffGoogleClientSecret"))
  }
}
