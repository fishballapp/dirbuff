import Foundation
import Testing

@testable import DirBuffKit

func itemJSON(
  _ id: String, name: String = "file", mime: String = "application/octet-stream",
  size: Int? = nil, parents: [String] = ["folder"], trashed: Bool = false, sha256: String? = nil,
  md5: String? = nil
) -> String {
  let fields: [String?] = [
    #""id": "\#(id)""#, #""name": "\#(name)""#, #""mimeType": "\#(mime)""#,
    size.map { #""size": "\#($0)""# },
    #""parents": [\#(parents.map { "\"\($0)\"" }.joined(separator: ","))]"#,
    #""trashed": \#(trashed)"#,
    sha256.map { #""sha256Checksum": "\#($0)""# }, md5.map { #""md5Checksum": "\#($0)""# },
  ]
  return "{" + fields.compactMap { $0 }.joined(separator: ",") + "}"
}

func driveError(_ status: Int, _ reason: String, _ message: String = "No") -> StubReply {
  .json(
    status,
    #"{"error": {"code": \#(status), "message": "\#(message)", "errors": [{"reason": "\#(reason)"}]}}"#
  )
}

/// A client whose pauses are recorded instead of waited.
func makeClient(
  tokens: any DriveAccessTokens = FixedTokens(),
  uploads: DriveClient.UploadPolicy = .standard,
  _ handler: @escaping StubNetwork.Handler
) -> (client: DriveClient, pauses: Locked<[Duration]>) {
  let pauses = Locked<[Duration]>([])
  let client = DriveClient(
    tokens: tokens, session: StubNetwork.session(handler), uploads: uploads,
    pause: { duration in pauses.withValue { $0.append(duration) } })
  return (client, pauses)
}

@Suite struct DriveClientTests {
  @Test func aboutReadsTheAddressAndTheRoom() async throws {
    let (client, _) = makeClient { request in
      #expect(request.method == "GET")
      #expect(request.url.path == "/drive/v3/about")
      #expect(request.header("Authorization") == "Bearer access-1")
      return .json(
        200,
        #"{"user": {"emailAddress": "jo@example.com"}, "storageQuota": {"limit": "16106127360", "usage": "1000"}}"#
      )
    }
    let about = try await client.about()
    #expect(
      about == DriveAbout(email: "jo@example.com", usedBytes: 1000, limitBytes: 16_106_127_360))
    #expect(about.freeBytes == Int64(16_106_126_360))
  }

  @Test func anAccountWithoutALimitHasNoFreeFigure() async throws {
    let (client, _) = makeClient { _ in
      .json(200, #"{"user": {"emailAddress": "a@b.c"}, "storageQuota": {"usage": "5"}}"#)
    }
    let about = try await client.about()
    #expect(about.limitBytes == nil)
    #expect(about.freeBytes == nil)
  }

  @Test func childrenAreAskedForByFolderAndFollowThePages() async throws {
    let (client, _) = makeClient { request in
      #expect(request.query["q"] == "'f1' in parents and trashed = false")
      #expect(request.query["pageSize"] == "1000")
      if request.query["pageToken"] == nil {
        return .json(200, #"{"nextPageToken": "t2", "files": [\#(itemJSON("a"))]}"#)
      }
      #expect(request.query["pageToken"] == "t2")
      return .json(200, #"{"files": [\#(itemJSON("b")), \#(itemJSON("c"))]}"#)
    }
    let all = try await client.allChildren(of: "f1")
    #expect(all.map(\.id) == ["a", "b", "c"])
  }

  @Test func everythingTheAppCreatedIsListedOutsideTheBin() async throws {
    let (client, _) = makeClient { request in
      #expect(request.query["q"] == "trashed = false")
      return .json(200, #"{"files": [\#(itemJSON("a", mime: DriveItem.folderMimeType))]}"#)
    }
    let all = try await client.allCreated()
    #expect(all.map(\.isFolder) == [true])
  }

  @Test func aFolderIdWithAQuoteCantEscapeTheQuery() async throws {
    let (client, _) = makeClient { request in
      #expect(request.query["q"] == #"'a\'b' in parents and trashed = false"#)
      return .json(200, #"{"files": []}"#)
    }
    _ = try await client.children(of: "a'b", after: nil)
  }

  @Test func foldersAreCreatedUnderTheirParent() async throws {
    let (client, _) = makeClient { request in
      #expect(request.method == "POST")
      #expect(request.json["name"] as? String == "Mac")
      #expect(request.json["parents"] as? [String] == ["root1"])
      #expect(request.json["mimeType"] as? String == DriveItem.folderMimeType)
      return .json(200, itemJSON("new", name: "Mac", mime: DriveItem.folderMimeType))
    }
    let folder = try await client.createFolder(named: "Mac", in: "root1")
    #expect(folder.id == "new")
    #expect(folder.isFolder)
  }

  @Test func metadataReadsSizeBinAndChecksums() async throws {
    let (client, _) = makeClient { request in
      #expect(request.url.path == "/drive/v3/files/x1")
      return .json(200, itemJSON("x1", size: 42, trashed: true, sha256: "ab", md5: "cd"))
    }
    let item = try await client.metadata(of: "x1")
    #expect(item.size == 42)
    #expect(item.isTrashed)
    #expect(item.sha256Checksum == "ab")
    #expect(item.md5Checksum == "cd")
  }

  @Test func untrashingClearsTheBinFlag() async throws {
    let (client, _) = makeClient { request in
      #expect(request.method == "PATCH")
      #expect(request.json["trashed"] as? Bool == false)
      return .json(200, itemJSON("x1"))
    }
    let item = try await client.untrash("x1")
    #expect(!item.isTrashed)
  }

  @Test func deletingIsPermanent() async throws {
    let (client, _) = makeClient { request in
      #expect(request.method == "DELETE")
      #expect(request.url.path == "/drive/v3/files/x1")
      return .reply(204)
    }
    try await client.delete("x1")
  }

  // MARK: Downloads

  @Test func aRangeIsAskedForWithItsLastByteIncluded() async throws {
    let (client, _) = makeClient { request in
      #expect(request.query["alt"] == "media")
      #expect(request.header("Range") == "bytes=10-19")
      return .reply(206, body: Data(repeating: 7, count: 10))
    }
    #expect(try await client.download("x1", range: 10..<20).count == 10)
  }

  @Test func aRangeGoogleIgnoredIsCutFromTheWholeFile() async throws {
    let (client, _) = makeClient { _ in .reply(200, body: Data(0..<10)) }
    #expect(try await client.download("x1", range: 2..<5) == Data([2, 3, 4]))
  }

  @Test func anEmptyRangeAsksNothing() async throws {
    let (client, _) = makeClient { _ in
      Issue.record("No request was wanted")
      return .reply(500)
    }
    #expect(try await client.download("x1", range: 5..<5).isEmpty)
  }

  @Test func withoutARangeTheWholeFileComes() async throws {
    let (client, _) = makeClient { request in
      #expect(request.header("Range") == nil)
      return .reply(200, body: Data([1, 2, 3]))
    }
    #expect(try await client.download("x1", range: nil) == Data([1, 2, 3]))
  }

  // MARK: Problems

  @Test(arguments: [
    (404, "notFound", DriveProblem.notFound),
    (403, "storageQuotaExceeded", .storageFull),
    (403, "dailyLimitExceeded", .dailyUploadLimit),
    (
      403, "appNotAuthorizedToFile",
      .rejected(status: 403, reason: "appNotAuthorizedToFile", message: "No")
    ),
    (400, "badRequest", .rejected(status: 400, reason: "badRequest", message: "No")),
  ])
  func googleRefusalsBecomeTypedProblems(status: Int, reason: String, problem: DriveProblem)
    async
  {
    let (client, pauses) = makeClient { _ in driveError(status, reason) }
    await #expect(throws: problem) { try await client.metadata(of: "x1") }
    #expect(pauses.withValue { $0 }.isEmpty)
  }

  @Test func anAnswerWithoutAnErrorBodyIsStillAProblem() async throws {
    let (client, _) = makeClient { _ in .reply(404) }
    await #expect(throws: DriveProblem.notFound) { try await client.metadata(of: "x1") }
  }

  @Test(arguments: [
    driveError(403, "userRateLimitExceeded"), driveError(403, "rateLimitExceeded"),
    .reply(429), .reply(503),
  ])
  func rateLimitsAreWaitedOutAndTheCallGoesThrough(limit: StubReply) async throws {
    let calls = Locked(0)
    let (client, pauses) = makeClient { _ in
      calls.increment() <= 2 ? limit : .json(200, itemJSON("x1"))
    }
    #expect(try await client.metadata(of: "x1").id == "x1")
    let waited: [Duration] = pauses.withValue { $0 }
    #expect(waited.count == 2)
    #expect(waited[0] >= .seconds(1) && waited[0] < .seconds(2))
    #expect(waited[1] >= .seconds(2) && waited[1] < .seconds(3))
  }

  @Test func theWaitDoublesUpToSixtyFourSecondsThenTheCallGivesUp() async throws {
    let (client, pauses) = makeClient { _ in .reply(429) }
    await #expect(throws: DriveProblem.rateLimited) { try await client.metadata(of: "x1") }
    let seconds = pauses.withValue { $0 }.map { Int($0.components.seconds) }
    #expect(seconds == [1, 2, 4, 8, 16, 32, 64, 64])
  }

  @Test func aGoogleThatKeepsFailingIsUnreachable() async throws {
    let (client, _) = makeClient { _ in .reply(502) }
    await #expect(throws: DriveProblem.unreachable) { try await client.metadata(of: "x1") }
  }

  @Test func noConnectionIsUnreachableWithoutWaiting() async throws {
    let (client, pauses) = makeClient { _ in .failure(.notConnectedToInternet) }
    await #expect(throws: DriveProblem.unreachable) { try await client.metadata(of: "x1") }
    #expect(pauses.withValue { $0 }.isEmpty)
  }

  // MARK: Tokens

  /// Hands out tokens and remembers who asked for a new one.
  private final class CountingTokens: DriveAccessTokens {
    let refreshes = Locked(0)
    func accessToken(forceRefresh: Bool) async throws -> String {
      forceRefresh ? "fresh-\(refreshes.increment())" : "stale"
    }
  }

  @Test func aRefusedTokenIsReplacedOnceAndTheCallRepeated() async throws {
    let tokens = CountingTokens()
    let (client, _) = makeClient(tokens: tokens) { request in
      request.header("Authorization") == "Bearer fresh-1"
        ? .json(200, itemJSON("x1")) : .reply(401)
    }
    #expect(try await client.metadata(of: "x1").id == "x1")
    #expect(tokens.refreshes.withValue { $0 } == 1)
  }

  @Test func aTokenRefusedAgainMeansSignedOut() async throws {
    let tokens = CountingTokens()
    let (client, _) = makeClient(tokens: tokens) { _ in .reply(401) }
    await #expect(throws: DriveProblem.signedOut) { try await client.metadata(of: "x1") }
    #expect(tokens.refreshes.withValue { $0 } == 1)
  }

  @Test func whenSigningInAgainIsNeededTheCallSaysSo() async throws {
    struct Revoked: DriveAccessTokens {
      func accessToken(forceRefresh: Bool) async throws -> String { throw DriveProblem.signedOut }
    }
    let (client, _) = makeClient(tokens: Revoked()) { _ in
      Issue.record("No request was wanted")
      return .reply(500)
    }
    await #expect(throws: DriveProblem.signedOut) { try await client.metadata(of: "x1") }
  }
}
