import AppKit
import CryptoKit
import Foundation

/// Signing in to Google as a desktop app: the user approves in their browser, Google redirects to
/// a one-off web server on 127.0.0.1, and the code in the redirect, proved by PKCE, is exchanged for
/// tokens. Only `drive.file` is asked for. The refresh token goes to the Keychain; access tokens
/// live in memory and are renewed as `DriveClient` needs them.
public actor GoogleSignIn: DriveAccessTokens {
  /// Why signing in didn't end in a signed-in user.
  public enum Failure: Error, Equatable, Sendable {
    /// This build has no Google client (`GoogleOAuthClient.isConfigured`).
    case notConfigured
    /// The user said no in the browser.
    case denied
    /// The user took `drive.file` off Google's consent screen, so there is nothing to back up to.
    case driveNotGranted
    /// The browser could not be opened.
    case browserUnavailable
    /// The local web server for Google's redirect could not start.
    case redirectUnavailable
    /// Nobody came back from the browser in time.
    case timedOut
  }

  static let scope = "https://www.googleapis.com/auth/drive.file"
  static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
  static let tokenEndpoint = URL(constant: "https://oauth2.googleapis.com/token")
  static let revocationEndpoint = URL(constant: "https://oauth2.googleapis.com/revoke")

  /// A token this close to expiring is renewed rather than risked.
  private static let renewalMargin: TimeInterval = 60

  private let client: GoogleOAuthClient
  private let store: any RefreshTokenStore
  private let session: URLSession
  private let openBrowser: @Sendable (URL) async -> Bool
  private let signInTimeout: Duration
  private let now: @Sendable () -> Date

  private var cached: (token: String, expires: Date)?
  private var renewal: Task<String, any Error>?

  public init(
    client: GoogleOAuthClient,
    store: any RefreshTokenStore,
    session: URLSession = .shared,
    openBrowser: @escaping @Sendable (URL) async -> Bool = { url in
      await MainActor.run { NSWorkspace.shared.open(url) }
    },
    signInTimeout: Duration = .seconds(300),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.client = client
    self.store = store
    self.session = session
    self.openBrowser = openBrowser
    self.signInTimeout = signInTimeout
    self.now = now
  }

  /// Whether a refresh token is stored. It may still turn out to be one Google has revoked.
  public func isSignedIn() throws -> Bool {
    try store.load() != nil
  }

  // MARK: Signing in

  public func signIn() async throws {
    guard client.isConfigured else { throw Failure.notConfigured }
    let verifier = Self.randomToken(byteCount: 32)
    let state = Self.randomToken(byteCount: 16)

    let redirect: LoopbackRedirect
    do {
      redirect = try await LoopbackRedirect.start()
    } catch is LoopbackRedirect.Unavailable {
      throw Failure.redirectUnavailable
    }
    defer { redirect.close() }

    guard await openBrowser(authorizationURL(redirect.redirectURI, verifier, state)) else {
      throw Failure.browserUnavailable
    }
    guard let answer = try await redirect.parameters(within: signInTimeout) else {
      throw Failure.timedOut
    }
    guard answer["state"] == state else {
      throw DriveProblem.rejected(
        status: 0, reason: nil, message: "The redirect wasn't an answer to this sign-in")
    }
    if let error = answer["error"] {
      throw error == "access_denied"
        ? Failure.denied
        : DriveProblem.rejected(status: 0, reason: error, message: "Google refused to sign in")
    }
    guard let code = answer["code"] else { throw Failure.denied }

    let tokens = try await requestTokens(
      [
        "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
        "redirect_uri": redirect.redirectURI, "client_id": client.id,
        "client_secret": client.secret,
      ])
    guard tokens.scope?.split(separator: " ").contains(Substring(Self.scope)) == true else {
      throw Failure.driveNotGranted
    }
    guard let refreshToken = tokens.refreshToken else {
      throw DriveProblem.rejected(
        status: 200, reason: nil, message: "Google gave no refresh token")
    }
    try store.save(refreshToken)
    cached = (tokens.accessToken, now().addingTimeInterval(tokens.expiresIn))
  }

  private func authorizationURL(_ redirectURI: String, _ verifier: String, _ state: String) -> URL {
    var components = URLComponents(string: Self.authorizationEndpoint)
    components?.queryItems = [
      ("client_id", client.id), ("redirect_uri", redirectURI), ("response_type", "code"),
      ("scope", Self.scope), ("state", state),
      ("code_challenge", Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
      ("code_challenge_method", "S256"),
      // Offline access and a fresh consent make Google issue a refresh token every time.
      ("access_type", "offline"), ("prompt", "consent"),
    ].map { URLQueryItem(name: $0, value: $1) }
    return components?.url ?? URL(fileURLWithPath: "/")
  }

  // MARK: Access tokens

  public func accessToken(forceRefresh: Bool) async throws -> String {
    if !forceRefresh, let cached, cached.expires.timeIntervalSince(now()) > Self.renewalMargin {
      return cached.token
    }
    if let renewal { return try await renewal.value }
    let renewal = Task { try await renewAccessToken() }
    self.renewal = renewal
    defer { self.renewal = nil }
    return try await renewal.value
  }

  private func renewAccessToken() async throws -> String {
    guard let refreshToken = try store.load() else { throw DriveProblem.signedOut }
    let tokens: TokenReply
    do {
      tokens = try await requestTokens(
        [
          "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": client.id,
          "client_secret": client.secret,
        ])
    } catch DriveProblem.rejected(_, "invalid_grant", _) {
      // Revoked, unused for 6 months, or ended by a session policy: the token is dead for good.
      cached = nil
      try store.delete()
      throw DriveProblem.signedOut
    }
    cached = (tokens.accessToken, now().addingTimeInterval(tokens.expiresIn))
    return tokens.accessToken
  }

  // MARK: Signing out

  /// Forgets the user and asks Google to revoke the token. The token is gone from this Mac either
  /// way; the result says whether Google confirmed, which an offline Mac can't get.
  @discardableResult
  public func signOut() async throws -> Bool {
    cached = nil
    guard let refreshToken = try store.load() else { return true }
    try store.delete()
    do {
      _ = try await postForm(Self.revocationEndpoint, ["token": refreshToken])
      return true
    } catch DriveProblem.rejected(_, "invalid_token", _) {
      return true
    } catch {
      return false
    }
  }

  // MARK: Google's token endpoint

  private struct TokenReply: Decodable {
    var accessToken: String
    var expiresIn: TimeInterval
    var refreshToken: String?
    var scope: String?

    private enum CodingKeys: String, CodingKey {
      case accessToken = "access_token"
      case expiresIn = "expires_in"
      case refreshToken = "refresh_token"
      case scope
    }
  }

  private struct OAuthError: Decodable { var error: String }

  /// A token request: its failures come back as `DriveProblem.rejected` carrying the OAuth error
  /// code (`invalid_grant`).
  private func requestTokens(_ form: [String: String]) async throws -> TokenReply {
    let (data, status) = try await postForm(Self.tokenEndpoint, form)
    do {
      return try JSONDecoder().decode(TokenReply.self, from: data)
    } catch {
      throw DriveProblem.rejected(
        status: status, reason: nil, message: "Google's token reply wasn't readable")
    }
  }

  /// A form POST that succeeded, with its body and status; otherwise `.unreachable` for no answer
  /// or a Google error, and `.rejected` carrying the OAuth error code for a refusal.
  private func postForm(_ endpoint: URL, _ form: [String: String]) async throws -> (Data, Int) {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(Self.formEncoded(form).utf8)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      try Task.checkCancellation()
      throw DriveProblem.unreachable
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard !(200..<300).contains(status) else { return (data, status) }
    guard status < 500, status != 429 else { throw DriveProblem.unreachable }
    throw DriveProblem.rejected(
      status: status, reason: (try? JSONDecoder().decode(OAuthError.self, from: data))?.error,
      message: "Google refused the request")
  }

  // MARK: Encoding

  static func randomToken(byteCount: Int) -> String {
    base64URL(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }))
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
  }

  private static func formEncoded(_ form: [String: String]) -> String {
    let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    func escaped(_ text: String) -> String {
      text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
    return form.sorted { $0.key < $1.key }.map { "\(escaped($0.key))=\(escaped($0.value))" }
      .joined(separator: "&")
  }
}
