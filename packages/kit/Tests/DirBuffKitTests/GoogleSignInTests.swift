import CryptoKit
import Foundation
import Testing

@testable import DirBuffKit

private final class MemoryTokenStore: RefreshTokenStore {
  private let token = Locked<String?>(nil)
  init(_ token: String? = nil) { self.token.withValue { $0 = token } }
  func load() throws -> String? { token.withValue { $0 } }
  func save(_ new: String) throws { token.withValue { $0 = new } }
  func delete() throws { token.withValue { $0 = nil } }
}

private let client = GoogleOAuthClient(id: "client-1", secret: "secret-1")

private func form(_ request: StubRequest) -> [String: String] {
  var components = URLComponents()
  components.percentEncodedQuery = String(decoding: request.body, as: UTF8.self)
  return (components.queryItems ?? []).reduce(into: [:]) { $0[$1.name] = $1.value }
}

private func tokenJSON(
  access: String = "access-1", refresh: String? = "refresh-1", expires: Int = 3600,
  scope: String = "https://www.googleapis.com/auth/drive.file"
) -> StubReply {
  let refresh = refresh.map { #""refresh_token": "\#($0)","# } ?? ""
  return .json(
    200,
    #"{"access_token": "\#(access)", \#(refresh) "expires_in": \#(expires), "scope": "\#(scope)", "token_type": "Bearer"}"#
  )
}

private func oauthError(_ code: String) -> StubReply {
  .json(400, #"{"error": "\#(code)", "error_description": "No"}"#)
}

/// Plays the browser: opens the sign-in URL's redirect with `answer` and gives the sign-in's own
/// query back to it.
private func browser(
  seen: Locked<[URL]> = Locked([]), answer: @escaping @Sendable (_ state: String) -> String
) -> @Sendable (URL) async -> Bool {
  { url in
    seen.withValue { $0.append(url) }
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard let redirect = query.first(where: { $0.name == "redirect_uri" })?.value,
      let state = query.first(where: { $0.name == "state" })?.value
    else { return false }
    Task {
      // A browser also asks for the favicon; that mustn't end the wait.
      _ = try? await URLSession.shared.data(from: URL(string: redirect + "/favicon.ico")!)
      _ = try? await URLSession.shared.data(from: URL(string: redirect + "/?" + answer(state))!)
    }
    return true
  }
}

@Suite struct GoogleSignInTests {
  // MARK: Signing in

  @Test func withoutAClientSigningInSaysNotConfigured() async throws {
    let opened = Locked(false)
    let signIn = GoogleSignIn(
      client: GoogleOAuthClient(id: "", secret: ""), store: MemoryTokenStore(),
      session: StubNetwork.session { _ in .reply(500) },
      openBrowser: { _ in
        opened.withValue { $0 = true }
        return true
      })
    await #expect(throws: GoogleSignIn.Failure.notConfigured) { try await signIn.signIn() }
    #expect(!opened.withValue { $0 })
    #expect(!GoogleOAuthClient(id: "id", secret: "").isConfigured)
    #expect(!GoogleOAuthClient(id: "", secret: "secret").isConfigured)
    #expect(client.isConfigured)
  }

  @Test func theBuildSettingsComeFromTheBundleAndAMissingOneIsEmpty() {
    #expect(!GoogleOAuthClient.fromInfoPlist(Bundle(for: BundleMarker.self)).isConfigured)
  }
  private final class BundleMarker {}

  @Test func signingInAsksForDriveFileOnlyAndProvesTheCodeWithPKCE() async throws {
    let seen = Locked<[URL]>([])
    let exchange = Locked<[String: String]>([:])
    let store = MemoryTokenStore()
    let signIn = GoogleSignIn(
      client: client, store: store,
      session: StubNetwork.session { request in
        #expect(request.url.absoluteString == "https://oauth2.googleapis.com/token")
        exchange.withValue { $0 = form(request) }
        return tokenJSON()
      },
      openBrowser: browser(seen: seen) { "code=the-code&state=\($0)" })

    try await signIn.signIn()

    let url = try #require(seen.withValue { $0.first })
    #expect(url.host == "accounts.google.com")
    let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
      .reduce(into: [String: String]()) { $0[$1.name] = $1.value }
    #expect(query["client_id"] == "client-1")
    #expect(query["scope"] == "https://www.googleapis.com/auth/drive.file")
    #expect(query["response_type"] == "code")
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["access_type"] == "offline")
    #expect(query["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)

    let sent = exchange.withValue { $0 }
    #expect(sent["grant_type"] == "authorization_code")
    #expect(sent["code"] == "the-code")
    #expect(sent["client_secret"] == "secret-1")
    #expect(sent["redirect_uri"] == query["redirect_uri"])
    let verifier = try #require(sent["code_verifier"])
    #expect(
      GoogleSignIn.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        == query["code_challenge"])

    #expect(try store.load() == "refresh-1")
    #expect(try await signIn.isSignedIn())
    // The access token that came with the code serves the first calls.
    #expect(try await signIn.accessToken(forceRefresh: false) == "access-1")
  }

  @Test func eachSignInHasItsOwnVerifierStateAndPort() async throws {
    let seen = Locked<[URL]>([])
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore(), session: StubNetwork.session { _ in tokenJSON() },
      openBrowser: browser(seen: seen) { "code=c&state=\($0)" })
    try await signIn.signIn()
    try await signIn.signIn()
    let urls = seen.withValue { $0 }
    #expect(urls.count == 2)
    #expect(Set(urls.map(\.query)).count == 2)
  }

  @Test func sayingNoInTheBrowserIsDenied() async throws {
    let store = MemoryTokenStore()
    let signIn = GoogleSignIn(
      client: client, store: store, session: StubNetwork.session { _ in .reply(500) },
      openBrowser: browser { "error=access_denied&state=\($0)" })
    await #expect(throws: GoogleSignIn.Failure.denied) { try await signIn.signIn() }
    #expect(try store.load() == nil)
  }

  @Test func aRedirectThatIsntAnAnswerToThisSignInIsRefused() async throws {
    let exchanged = Locked(false)
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore(),
      session: StubNetwork.session { _ in
        exchanged.withValue { $0 = true }
        return tokenJSON()
      },
      openBrowser: browser { _ in "code=forged&state=not-ours" })
    await #expect(throws: DriveProblem.self) { try await signIn.signIn() }
    #expect(!exchanged.withValue { $0 })
  }

  @Test func untickingDriveOnTheConsentScreenIsNotSignedIn() async throws {
    let store = MemoryTokenStore()
    let signIn = GoogleSignIn(
      client: client, store: store,
      session: StubNetwork.session { _ in tokenJSON(scope: "openid") },
      openBrowser: browser { "code=c&state=\($0)" })
    await #expect(throws: GoogleSignIn.Failure.driveNotGranted) { try await signIn.signIn() }
    #expect(try store.load() == nil)
  }

  @Test func aTokenReplyWithoutARefreshTokenIsRefused() async throws {
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore(),
      session: StubNetwork.session { _ in tokenJSON(refresh: nil) },
      openBrowser: browser { "code=c&state=\($0)" })
    await #expect(throws: DriveProblem.self) { try await signIn.signIn() }
  }

  @Test func googleRefusingTheCodeIsRejectedWithItsReason() async throws {
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore(),
      session: StubNetwork.session { _ in oauthError("invalid_grant") },
      openBrowser: browser { "code=c&state=\($0)" })
    await #expect(
      throws: DriveProblem.rejected(
        status: 400, reason: "invalid_grant", message: "Google refused the request")
    ) { try await signIn.signIn() }
  }

  @Test func aBrowserThatWontOpenIsReported() async throws {
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore(), session: StubNetwork.session { _ in .reply(500) },
      openBrowser: { _ in false })
    await #expect(throws: GoogleSignIn.Failure.browserUnavailable) { try await signIn.signIn() }
  }

  @Test func nobodyComingBackTimesOut() async throws {
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore(), session: StubNetwork.session { _ in .reply(500) },
      openBrowser: { _ in true }, signInTimeout: .milliseconds(150))
    await #expect(throws: GoogleSignIn.Failure.timedOut) { try await signIn.signIn() }
  }

  @Test func cancellingWhileWaitingForTheBrowserStops() async throws {
    let browserOpened = Signal()
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore(), session: StubNetwork.session { _ in .reply(500) },
      openBrowser: { _ in
        await browserOpened.send()
        return true
      })
    let attempt = Task { try await signIn.signIn() }
    // It waits for the browser to come back once it has sent the user there.
    await browserOpened.wait()
    attempt.cancel()
    await #expect(throws: CancellationError.self) { try await attempt.value }
  }

  // MARK: Access tokens

  @Test func aStoredRefreshTokenBuysAnAccessTokenThatIsKeptUntilItExpires() async throws {
    let requests = Locked<[[String: String]]>([])
    let clock = Locked(Date(timeIntervalSince1970: 1000))
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore("refresh-9"),
      session: StubNetwork.session { request in
        requests.withValue { $0.append(form(request)) }
        return tokenJSON(
          access: "access-\(requests.withValue { $0.count })", refresh: nil, expires: 3600)
      },
      now: { clock.withValue { $0 } })

    #expect(try await signIn.accessToken(forceRefresh: false) == "access-1")
    #expect(requests.withValue { $0[0] }["grant_type"] == "refresh_token")
    #expect(requests.withValue { $0[0] }["refresh_token"] == "refresh-9")
    #expect(try await signIn.accessToken(forceRefresh: false) == "access-1")
    #expect(requests.withValue { $0.count } == 1)

    clock.withValue { $0 = $0.addingTimeInterval(3600 - 30) }  // inside the one-minute margin
    #expect(try await signIn.accessToken(forceRefresh: false) == "access-2")
  }

  @Test func aRefusedTokenIsReplacedEvenWhileItsClockSaysItIsGood() async throws {
    let count = Locked(0)
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore("refresh-9"),
      session: StubNetwork.session { _ in
        tokenJSON(access: "access-\(count.increment())", refresh: nil)
      })
    #expect(try await signIn.accessToken(forceRefresh: false) == "access-1")
    #expect(try await signIn.accessToken(forceRefresh: true) == "access-2")
  }

  @Test func callsAskingAtTheSameTimeShareOneRefresh() async throws {
    let count = Locked(0)
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore("refresh-9"),
      session: StubNetwork.session { _ in
        count.withValue { $0 += 1 }
        return tokenJSON(refresh: nil)
      })
    let tokens = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<5 { group.addTask { try await signIn.accessToken(forceRefresh: false) } }
      return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(Set(tokens) == ["access-1"])
    #expect(count.withValue { $0 } == 1)
  }

  @Test func aRevokedRefreshTokenMeansSignedOutAndIsForgotten() async throws {
    let store = MemoryTokenStore("refresh-9")
    let signIn = GoogleSignIn(
      client: client, store: store,
      session: StubNetwork.session { _ in oauthError("invalid_grant") })
    await #expect(throws: DriveProblem.signedOut) {
      try await signIn.accessToken(forceRefresh: false)
    }
    #expect(try store.load() == nil)
    #expect(try await !signIn.isSignedIn())
  }

  @Test func noRefreshTokenMeansSignedOutWithoutAsking() async throws {
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore(),
      session: StubNetwork.session { _ in
        Issue.record("No request was wanted")
        return .reply(500)
      })
    await #expect(throws: DriveProblem.signedOut) {
      try await signIn.accessToken(forceRefresh: false)
    }
  }

  @Test(arguments: [StubReply.failure(.notConnectedToInternet), .reply(503), .reply(429)])
  func noAnswerFromGoogleKeepsTheUserSignedIn(answer: StubReply) async throws {
    let store = MemoryTokenStore("refresh-9")
    let signIn = GoogleSignIn(
      client: client, store: store, session: StubNetwork.session { _ in answer })
    await #expect(throws: DriveProblem.unreachable) {
      try await signIn.accessToken(forceRefresh: false)
    }
    #expect(try store.load() == "refresh-9")
  }

  @Test func valuesWithSymbolsSurviveTheFormEncoding() async throws {
    let sent = Locked<[String: String]>([:])
    let signIn = GoogleSignIn(
      client: GoogleOAuthClient(id: "id", secret: "se+cr&et=/"),
      store: MemoryTokenStore("a+b/c=d&e"),
      session: StubNetwork.session { request in
        sent.withValue { $0 = form(request) }
        return tokenJSON(refresh: nil)
      })
    _ = try await signIn.accessToken(forceRefresh: false)
    #expect(sent.withValue { $0 }["refresh_token"] == "a+b/c=d&e")
    #expect(sent.withValue { $0 }["client_secret"] == "se+cr&et=/")
  }

  // MARK: Signing out

  @Test func signingOutRevokesTheTokenAndDeletesIt() async throws {
    let store = MemoryTokenStore("refresh-9")
    let revoked = Locked<[String: String]>([:])
    let signIn = GoogleSignIn(
      client: client, store: store,
      session: StubNetwork.session { request in
        #expect(request.url.absoluteString == "https://oauth2.googleapis.com/revoke")
        revoked.withValue { $0 = form(request) }
        return .reply(200)
      })
    #expect(try await signIn.signOut())
    #expect(revoked.withValue { $0 }["token"] == "refresh-9")
    #expect(try store.load() == nil)
  }

  @Test func signingOutOfflineStillForgetsTheUserAndSaysGoogleDidntConfirm() async throws {
    let store = MemoryTokenStore("refresh-9")
    let signIn = GoogleSignIn(
      client: client, store: store,
      session: StubNetwork.session { _ in .failure(.notConnectedToInternet) })
    #expect(try await !signIn.signOut())
    #expect(try store.load() == nil)
    await #expect(throws: DriveProblem.signedOut) {
      try await signIn.accessToken(forceRefresh: false)
    }
  }

  @Test func aTokenGoogleAlreadyRevokedCountsAsRevoked() async throws {
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore("refresh-9"),
      session: StubNetwork.session { _ in oauthError("invalid_token") })
    #expect(try await signIn.signOut())
  }

  @Test func signingOutWhenSignedOutAsksNothing() async throws {
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore(),
      session: StubNetwork.session { _ in
        Issue.record("No request was wanted")
        return .reply(500)
      })
    #expect(try await signIn.signOut())
  }

  @Test func theAccessTokenDoesNotOutliveSigningOut() async throws {
    let signIn = GoogleSignIn(
      client: client, store: MemoryTokenStore("refresh-9"),
      session: StubNetwork.session { request in
        request.url.path == "/revoke" ? .reply(200) : tokenJSON(refresh: nil)
      })
    _ = try await signIn.accessToken(forceRefresh: false)
    try await signIn.signOut()
    await #expect(throws: DriveProblem.signedOut) {
      try await signIn.accessToken(forceRefresh: false)
    }
  }
}

// MARK: Keychain

/// Whether this Mac lets the tests use a Keychain (a CI Mac may have none that is unlocked).
private let canUseKeychain: Bool = {
  let probe = KeychainRefreshTokenStore(service: "app.fishball.dirbuff.tests", account: "probe")
  defer { try? probe.delete() }
  return (try? probe.save("probe")) != nil
}()

@Suite struct KeychainRefreshTokenStoreTests {
  @Test(.enabled(if: canUseKeychain, "No usable Keychain on this Mac"))
  func theTokenRoundTripsThroughTheLoginKeychainAndIsDeleted() throws {
    let store = KeychainRefreshTokenStore(
      service: "app.fishball.dirbuff.tests", account: "round-trip-\(UUID().uuidString)")
    defer { try? store.delete() }
    #expect(try store.load() == nil)
    try store.save("first")
    #expect(try store.load() == "first")
    try store.save("second")
    #expect(try store.load() == "second")
    try store.delete()
    #expect(try store.load() == nil)
    try store.delete()
  }
}
