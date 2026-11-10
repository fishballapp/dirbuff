import CryptoKit
import Foundation
import Testing

@testable import DirBuffKit

private func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func md5(_ data: Data) -> String {
  Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// The part of Drive that takes resumable uploads: sessions that remember what they were sent,
/// and the faults a long upload meets.
private final class FakeUploadServer: @unchecked Sendable {
  struct State {
    var sessions: [Data] = []
    var chunkRanges: [String] = []
    var asks = 0
    var deleted: [String] = []
    var chunksSent = 0
  }

  /// The nth chunk (1-based) is stored but its reply never arrives.
  var losesReplyOfChunk: Int?
  /// The nth chunk (1-based) never reaches Drive and no reply comes.
  var dropsChunk: Int?
  /// Every question about progress is answered with a 404, as for an expired session.
  var expiresSessionsWhenAsked = false
  /// Drive stores a different file than was sent.
  var corrupts = false

  let state = Locked(State())

  func handle(_ request: StubRequest) -> StubReply {
    if request.method == "DELETE" {
      state.withValue { $0.deleted.append(request.url.lastPathComponent) }
      return .reply(204)
    }
    if request.query["uploadType"] == "resumable", request.method == "POST" {
      let id = state.withValue { state in
        state.sessions.append(Data())
        return state.sessions.count - 1
      }
      return .reply(
        200,
        headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=\(id)"])
    }
    guard request.method == "PUT", let id = request.query["upload_id"].flatMap({ Int($0) }),
      let range = request.header("Content-Range")
    else { return .reply(400) }
    return range.hasPrefix("bytes */") ? ask(id, range) : chunk(id, range, request.body)
  }

  private func ask(_ id: Int, _ range: String) -> StubReply {
    state.withValue { $0.asks += 1 }
    if expiresSessionsWhenAsked { return .reply(404) }
    return progress(id, total: Int(range.dropFirst("bytes */".count)) ?? 0)
  }

  private func chunk(_ id: Int, _ range: String, _ body: Data) -> StubReply {
    let parts = range.dropFirst("bytes ".count).split(whereSeparator: { "-/".contains($0) })
    guard parts.count == 3, let first = Int(parts[0]), let total = Int(parts[2]) else {
      return .reply(400)
    }
    let number = state.withValue { state in
      state.chunksSent += 1
      state.chunkRanges.append(range)
      return state.chunksSent
    }
    if number == dropsChunk { return .failure(.networkConnectionLost) }
    let stored = state.withValue { state in
      guard state.sessions[id].count == first else { return false }
      state.sessions[id].append(body)
      return true
    }
    guard stored else { return .reply(400) }
    if number == losesReplyOfChunk { return .failure(.timedOut) }
    return progress(id, total: total)
  }

  private func progress(_ id: Int, total: Int) -> StubReply {
    let received = state.withValue { $0.sessions[id] }
    if received.count < total {
      return .reply(
        308, headers: received.isEmpty ? [:] : ["Range": "bytes=0-\(received.count - 1)"])
    }
    let kept = corrupts ? received + Data([0]) : received
    return .json(200, itemJSON("up\(id)", size: kept.count, sha256: sha256(kept)))
  }
}

@Suite struct DriveUploadTests {
  static let quantum = 256 << 10
  static let policy = DriveClient.UploadPolicy(multipartLimit: 1000, chunkSize: quantum)
  /// Four chunks, the last one short.
  static let large = Data((0..<(3 * quantum + 1000)).map { UInt8($0 % 251) })

  // MARK: Multipart

  @Test func aSmallFileGoesUpInOneMultipartRequest() async throws {
    let data = Data("hello pack".utf8)
    let (client, _) = makeClient { request in
      #expect(request.method == "POST")
      #expect(request.query["uploadType"] == "multipart")
      #expect(request.header("Content-Type")?.hasPrefix("multipart/related; boundary=") == true)
      let body = String(decoding: request.body, as: UTF8.self)
      #expect(body.contains(#""name":"abc""#))
      #expect(body.contains(#""parents":["folder"]"#))
      #expect(body.contains("hello pack"))
      return .json(200, itemJSON("f1", name: "abc", size: data.count, sha256: sha256(data)))
    }
    let item = try await client.upload(data, named: "abc", in: "folder")
    #expect(item.id == "f1")
  }

  @Test func md5IsTheProofWhenDriveGivesNoSha256() async throws {
    let data = Data("older file".utf8)
    let (client, _) = makeClient { _ in .json(200, itemJSON("f1", md5: md5(data))) }
    #expect(try await client.upload(data, named: "abc", in: "folder").id == "f1")
  }

  @Test func aFileDriveStoredDifferentlyIsRemovedAndRefused() async throws {
    let deleted = Locked<[String]>([])
    let (client, _) = makeClient { request in
      if request.method == "DELETE" {
        deleted.withValue { $0.append(request.url.lastPathComponent) }
        return .reply(204)
      }
      return .json(200, itemJSON("bad", sha256: sha256(Data("something else".utf8))))
    }
    let data = Data("hello".utf8)
    await #expect(
      throws: DriveProblem.checksumMismatch(
        sent: sha256(data), stored: sha256(Data("something else".utf8)))
    ) {
      try await client.upload(data, named: "abc", in: "folder")
    }
    #expect(deleted.withValue { $0 } == ["bad"])
  }

  @Test func aFileWithNoChecksumAtAllIsNotTakenAsStored() async throws {
    let (client, _) = makeClient { request in
      request.method == "DELETE" ? .reply(204) : .json(200, itemJSON("f1"))
    }
    let data = Data("hello".utf8)
    await #expect(throws: DriveProblem.checksumMismatch(sent: md5(data), stored: nil)) {
      try await client.upload(data, named: "abc", in: "folder")
    }
  }

  @Test func theStorageQuotaStopsAnUploadWithoutRetries() async throws {
    let (client, pauses) = makeClient { _ in driveError(403, "storageQuotaExceeded") }
    await #expect(throws: DriveProblem.storageFull) {
      try await client.upload(Data("x".utf8), named: "abc", in: "folder")
    }
    #expect(pauses.withValue { $0 }.isEmpty)
  }

  // MARK: Resumable

  @Test func aLargeFileGoesUpInChunksOfTheSizeOfTheirPolicy() async throws {
    let server = FakeUploadServer()
    let (client, _) = makeClient(uploads: Self.policy) { server.handle($0) }
    let item = try await client.upload(Self.large, named: "big", in: "folder")
    #expect(item.size == Int64(Self.large.count))
    let ranges = server.state.withValue { $0.chunkRanges }
    let total = Self.large.count
    let q = Self.quantum
    #expect(
      ranges == [
        "bytes 0-\(q - 1)/\(total)", "bytes \(q)-\(2 * q - 1)/\(total)",
        "bytes \(2 * q)-\(3 * q - 1)/\(total)", "bytes \(3 * q)-\(total - 1)/\(total)",
      ])
    #expect(server.state.withValue { $0.asks } == 0)
  }

  @Test func theSessionIsOpenedWithTheMetadataAndTheSize() async throws {
    let server = FakeUploadServer()
    let (client, _) = makeClient(uploads: Self.policy) { request in
      if request.query["uploadType"] == "resumable" {
        #expect(request.json["name"] as? String == "big")
        #expect(request.json["parents"] as? [String] == ["folder"])
        #expect(request.header("X-Upload-Content-Length") == String(Self.large.count))
        #expect(request.header("X-Upload-Content-Type") == "application/octet-stream")
      }
      return server.handle(request)
    }
    _ = try await client.upload(Self.large, named: "big", in: "folder")
  }

  @Test func chunkSizesAreMultiplesOfTwoHundredFiftySixKibibytes() {
    #expect(DriveClient.UploadPolicy.standard.chunkSize == 16 << 20)
    #expect(DriveClient.UploadPolicy(multipartLimit: 0, chunkSize: 300_000).chunkSize == 262_144)
    #expect(DriveClient.UploadPolicy(multipartLimit: 0, chunkSize: 1).chunkSize == 262_144)
  }

  @Test func aChunkWhoseReplyWasLostIsNotSentTwice() async throws {
    let server = FakeUploadServer()
    server.losesReplyOfChunk = 2
    let (client, pauses) = makeClient(uploads: Self.policy) { server.handle($0) }
    let item = try await client.upload(Self.large, named: "big", in: "folder")
    #expect(item.size == Int64(Self.large.count))
    let state = server.state.withValue { $0 }
    // Drive had chunk 2, said so when asked, and the upload went on from chunk 3.
    #expect(state.asks == 1)
    #expect(state.chunksSent == 4)
    #expect(state.sessions.count == 1)
    #expect(pauses.withValue { $0 }.count == 1)
  }

  @Test func aChunkThatNeverArrivedIsSentAgainAfterAsking() async throws {
    let server = FakeUploadServer()
    server.dropsChunk = 2
    let (client, _) = makeClient(uploads: Self.policy) { server.handle($0) }
    _ = try await client.upload(Self.large, named: "big", in: "folder")
    let state = server.state.withValue { $0 }
    #expect(state.asks == 1)
    #expect(state.chunksSent == 5)
    #expect(state.chunkRanges[2] == state.chunkRanges[1])
  }

  @Test func anUploadThatHasReceivedNothingStartsFromTheBeginningAgain() async throws {
    let server = FakeUploadServer()
    server.dropsChunk = 1
    let (client, _) = makeClient(uploads: Self.policy) { server.handle($0) }
    _ = try await client.upload(Self.large, named: "big", in: "folder")
    #expect(
      server.state.withValue { $0.chunkRanges.prefix(2) }
        == ArraySlice(
          [
            "bytes 0-\(Self.quantum - 1)/\(Self.large.count)",
            "bytes 0-\(Self.quantum - 1)/\(Self.large.count)",
          ]))
  }

  @Test func anExpiredSessionMeansStartingOverInANewOne() async throws {
    let server = FakeUploadServer()
    server.losesReplyOfChunk = 2
    server.expiresSessionsWhenAsked = true
    let (client, _) = makeClient(uploads: Self.policy) { request in
      // The new session answers questions again.
      if request.query["upload_id"] == "1" { server.expiresSessionsWhenAsked = false }
      return server.handle(request)
    }
    let item = try await client.upload(Self.large, named: "big", in: "folder")
    #expect(item.id == "up1")
    #expect(server.state.withValue { $0.sessions.count } == 2)
  }

  @Test func aSessionThatNeverAnswersIsGivenUp() async throws {
    let (client, pauses) = makeClient(uploads: Self.policy) { request in
      request.query["uploadType"] == "resumable"
        ? .reply(
          200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=0"]
        )
        : .failure(.timedOut)
    }
    await #expect(throws: DriveProblem.unreachable) {
      try await client.upload(Self.large, named: "big", in: "folder")
    }
    #expect(pauses.withValue { $0 }.count == DriveClient.maxSilentFailures)
  }

  @Test func aLargeFileDriveStoredDifferentlyIsRemovedAndRefused() async throws {
    let server = FakeUploadServer()
    server.corrupts = true
    let (client, _) = makeClient(uploads: Self.policy) { server.handle($0) }
    await #expect(throws: DriveProblem.self) {
      try await client.upload(Self.large, named: "big", in: "folder")
    }
    #expect(server.state.withValue { $0.deleted } == ["up0"])
  }

  @Test func aSessionOfferingNoLocationIsRefused() async throws {
    let (client, _) = makeClient(uploads: Self.policy) { _ in .reply(200) }
    await #expect(throws: DriveProblem.self) {
      try await client.upload(Self.large, named: "big", in: "folder")
    }
  }

  @Test func rateLimitsOnAChunkAreWaitedOutLikeAnyOther() async throws {
    let server = FakeUploadServer()
    let limited = Locked(false)
    let (client, pauses) = makeClient(uploads: Self.policy) { request in
      if request.method == "PUT", request.header("Content-Range")?.hasPrefix("bytes 0-") == true,
        !limited.withValue({
          let was = $0
          $0 = true
          return was
        })
      {
        return driveError(403, "userRateLimitExceeded")
      }
      return server.handle(request)
    }
    _ = try await client.upload(Self.large, named: "big", in: "folder")
    #expect(pauses.withValue { $0 }.count == 1)
    #expect(server.state.withValue { $0.asks } == 0)
  }
}
