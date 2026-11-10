import Foundation
import Testing

@testable import DirBuffKit

/// The bridge's answers to single requests, and the ID table under them.
@Suite struct BridgeServerTests {
  let name = String(repeating: "ab", count: 32)
  let otherName = "ab" + String(repeating: "cd", count: 31)

  func request(
    _ method: String, _ path: String, headers: [String: String] = [:], body: Data = Data()
  ) -> HTTPRequest {
    HTTPRequest(method: method, path: path, query: [:], headers: headers, body: body)
  }

  @Test func aFileIsWrittenIntoItsShardAndReadBackByRange() async throws {
    let fixture = try await BridgeFixture()
    let server = BridgeServer(fixture.bridge)
    let bytes = Data("0123456789".utf8)

    #expect(await server.respond(to: request("POST", "/data/\(name)", body: bytes)).status == 200)
    #expect(Array(try await fixture.filesOnDrive().keys) == ["data/ab/\(name)"])

    let head = await server.respond(to: request("HEAD", "/data/\(name)"))
    #expect(head.status == 200)
    #expect(head.contentLength == 10)

    let part = await server.respond(
      to: request("GET", "/data/\(name)", headers: ["range": "bytes=2-4"]))
    #expect(part.status == 206)
    #expect(part.body == Data("234".utf8))
    #expect(part.headers["Content-Range"] == "bytes 2-4/10")

    let rest = await server.respond(
      to: request("GET", "/data/\(name)", headers: ["range": "bytes=8-"]))
    #expect(rest.body == Data("89".utf8))
    let past = await server.respond(
      to: request("GET", "/data/\(name)", headers: ["range": "bytes=10-"]))
    #expect(past.status == 416)
  }

  @Test func listingsComeFromTheTableAndNeverAskDrive() async throws {
    let fixture = try await BridgeFixture()
    let server = BridgeServer(fixture.bridge)
    _ = await server.respond(to: request("POST", "/data/\(name)", body: Data("12345".utf8)))
    _ = await server.respond(to: request("POST", "/data/\(otherName)", body: Data("1".utf8)))
    await fixture.drive.clearCalls()

    let listing = await server.respond(
      to: request("GET", "/data/", headers: ["accept": "application/vnd.x.restic.rest.v2"]))
    #expect(listing.headers["Content-Type"] == "application/vnd.x.restic.rest.v2")
    let entries = try JSONDecoder().decode([ListedFile].self, from: listing.body)
    #expect(entries == [ListedFile(name: name, size: 5), ListedFile(name: otherName, size: 1)])
    #expect(await fixture.drive.calls.isEmpty)
  }

  @Test func aRetriedWriteOfTheSameFileSucceedsWithoutUploadingAgain() async throws {
    let fixture = try await BridgeFixture()
    let server = BridgeServer(fixture.bridge)
    let pack = Data("pack".utf8)
    #expect(await server.respond(to: request("POST", "/data/\(name)", body: pack)).status == 200)
    #expect(await server.respond(to: request("POST", "/data/\(name)", body: pack)).status == 200)
    #expect(await fixture.drive.calls.filter { $0 == "upload" }.count == 1)
    #expect(try fixture.store.uploads(since: .distantPast).count == 1)

    // A file is never replaced: another size under the same name is someone's mistake.
    let other = await server.respond(
      to: request("POST", "/data/\(name)", body: Data("other".utf8)))
    #expect(other.status == 403)
  }

  @Test func aRetriedConfigSucceedsOnlyWithTheSameBytes() async throws {
    let fixture = try await BridgeFixture()
    let server = BridgeServer(fixture.bridge)
    #expect(
      await server.respond(to: request("POST", "/config", body: Data("abc".utf8))).status == 200)
    #expect(
      await server.respond(to: request("POST", "/config", body: Data("abc".utf8))).status == 200)
    #expect(
      await server.respond(to: request("POST", "/config", body: Data("abd".utf8))).status == 403)
    #expect(await fixture.drive.calls.filter { $0 == "upload" }.count == 1)
  }

  @Test func writesOfOneFileAtOnceShareOneUpload() async throws {
    let fixture = try await BridgeFixture()
    let server = BridgeServer(fixture.bridge)
    let pack = Data(count: 1_000)
    async let first = server.respond(to: request("POST", "/data/\(name)", body: pack))
    async let retry = server.respond(to: request("POST", "/data/\(name)", body: pack))
    #expect(await [first.status, retry.status] == [200, 200])
    #expect(await fixture.drive.calls.filter { $0 == "upload" }.count == 1)
    #expect(try fixture.store.uploads(since: .distantPast).map(\.bytes) == [1_000])
  }

  @Test func locksGoUpWhileUploadsArePausedAndAreNotCounted() async throws {
    let fixture = try await BridgeFixture(dailyUploadLimit: 10)
    let server = BridgeServer(fixture.bridge)
    let paused = await server.respond(to: request("POST", "/data/\(name)", body: Data(count: 20)))
    #expect(paused.status == 507)

    let lock = await server.respond(to: request("POST", "/locks/\(name)", body: Data(count: 20)))
    #expect(lock.status == 200)
    #expect(try fixture.store.uploads(since: .distantPast).isEmpty)
    #expect(
      await server.failure == .uploadPaused(until: BridgeFixture.now.addingTimeInterval(86_400)))
  }

  @Test func theFirstFailureThatStopsRequestsIsTheOneReported() async throws {
    let fixture = try await BridgeFixture()
    let server = BridgeServer(fixture.bridge)
    // A checksum mismatch is only that request's: restic retries it.
    await fixture.drive.failNextCall(with: .checksumMismatch(sent: "a", stored: "b"))
    #expect(
      await server.respond(to: request("POST", "/data/\(name)", body: Data(count: 5))).status == 500
    )
    #expect(await server.failure == nil)

    await fixture.drive.failNextCall(with: .storageFull)
    _ = await server.respond(to: request("POST", "/data/\(otherName)", body: Data(count: 5)))
    await fixture.drive.failNextCall(with: .signedOut)
    _ = await server.respond(to: request("POST", "/locks/\(name)", body: Data(count: 5)))
    #expect(await server.failure == .drive(.storageFull))
  }

  @Test func aFolderAlreadyInDriveIsUsedRatherThanMadeAgain() async throws {
    let fixture = try await BridgeFixture()
    // A create whose reply was lost: the folders are in Drive, but not in the table.
    let data = try await fixture.drive.createFolder(named: "data", in: fixture.repository)
    let shard = try await fixture.drive.createFolder(named: "ab", in: data.id)
    let server = BridgeServer(fixture.bridge)

    #expect(
      await server.respond(to: request("POST", "/data/\(name)", body: Data(count: 5))).status == 200
    )
    #expect(try await fixture.drive.allChildren(of: fixture.repository).map(\.name) == ["data"])
    #expect(try await fixture.drive.allChildren(of: data.id).map(\.name) == ["ab"])
    #expect(try await fixture.drive.allChildren(of: shard.id).count == 1)
  }

  @Test func aRebuildKeepsTheCopyOfAFolderThatHoldsFiles() async throws {
    let fixture = try await BridgeFixture()
    let data = try await fixture.drive.createFolder(named: "data", in: fixture.repository)
    _ = try await fixture.drive.createFolder(named: "ab", in: data.id)
    let used = try await fixture.drive.createFolder(named: "ab", in: data.id)
    _ = try await fixture.drive.upload(Data(count: 5), named: name, in: used.id)
    _ = try await fixture.drive.createFolder(named: "ab", in: data.id)

    try await fixture.bridge.rebuildTable()
    #expect(
      try fixture.store.repositoryFiles(in: fixture.repository, at: "data/ab").map(\.driveID) == [
        used.id
      ])

    let server = BridgeServer(fixture.bridge)
    _ = await server.respond(to: request("POST", "/data/\(otherName)", body: Data(count: 5)))
    #expect(try await fixture.drive.allChildren(of: used.id).count == 2)
  }

  @Test func requestsOutsideTheLayoutAreRefused() async throws {
    let fixture = try await BridgeFixture()
    let server = BridgeServer(fixture.bridge)
    #expect(await server.respond(to: request("GET", "/data/not-a-hash")).status == 400)
    #expect(await server.respond(to: request("GET", "/password.txt")).status == 404)
    #expect(await server.respond(to: request("DELETE", "/")).status == 501)
    #expect(await server.respond(to: request("DELETE", "/keys/\(name)")).status == 404)
  }

  @Test func twoUploadsIntoANewFolderMakeOneFolder() async throws {
    let fixture = try await BridgeFixture()
    let server = BridgeServer(fixture.bridge)
    async let first = server.respond(to: request("POST", "/data/\(name)", body: Data("1".utf8)))
    async let second = server.respond(
      to: request("POST", "/data/\(otherName)", body: Data("2".utf8)))
    #expect(await [first.status, second.status] == [200, 200])
    let data = try #require(
      try await fixture.drive.allChildren(of: fixture.repository).first { $0.name == "data" })
    #expect(try await fixture.drive.allChildren(of: data.id).map(\.name) == ["ab"])
  }

  @Test func configAndKeysAreReadFromDriveOnceThenFromTheTable() async throws {
    let fixture = try await BridgeFixture()
    _ = try await fixture.bridge.serving(fixture.restic) { try await $0.createRepository() }

    await fixture.drive.clearCalls()
    _ = try await fixture.bridge.serving(fixture.restic) { try await $0.snapshots() }
    // Only the command's lock goes to Drive and back.
    #expect(await fixture.drive.calls == ["upload", "delete"])

    // A rebuilt table knows only what Drive lists, so it reads them again, once.
    try await fixture.bridge.rebuildTable()
    for _ in 0..<2 {
      _ = try await fixture.bridge.serving(fixture.restic) { try await $0.snapshots() }
    }
    #expect(await fixture.drive.calls.filter { $0 == "download" }.count == 2)
  }

  @Test func aRebuiltTableHoldsEveryCopyOfAFileAndDeleteRemovesThemAll() async throws {
    let fixture = try await BridgeFixture()
    let server = BridgeServer(fixture.bridge)
    _ = await server.respond(to: request("POST", "/locks/\(name)", body: Data("lock".utf8)))
    // An upload retried after its reply was lost: Drive holds the name twice.
    let locks = try #require(
      try await fixture.drive.allChildren(of: fixture.repository).first { $0.name == "locks" })
    _ = try await fixture.drive.upload(Data("lock".utf8), named: name, in: locks.id)

    try await fixture.bridge.rebuildTable()
    #expect(
      try fixture.store.repositoryFiles(in: fixture.repository, at: "locks/\(name)").count == 2)
    let listing = await server.respond(to: request("GET", "/locks/"))
    #expect(try JSONDecoder().decode([String].self, from: listing.body) == [name])

    #expect(await server.respond(to: request("DELETE", "/locks/\(name)")).status == 200)
    #expect(try await fixture.drive.allChildren(of: locks.id).isEmpty)
    #expect(await server.respond(to: request("HEAD", "/locks/\(name)")).status == 404)
  }

  @Test func theRebuildLeavesOutWhatIsntInTheRepository() async throws {
    let fixture = try await BridgeFixture()
    let elsewhere = try await fixture.drive.createFolder(named: "Other Mac", in: nil)
    _ = try await fixture.drive.upload(Data("x".utf8), named: "config", in: elsewhere.id)
    _ = try await fixture.drive.upload(Data("c".utf8), named: "config", in: fixture.repository)

    try await fixture.bridge.rebuildTable()
    let files = try fixture.store.repositoryFiles(in: fixture.repository, at: "config")
    #expect(files.map(\.size) == [1])
  }

  @Test func theLimitLiftsOnceEnoughOfTheDayIsADayOld() {
    let start = BridgeFixture.now
    let uploads = [
      DriveUpload(at: start, bytes: 40),
      DriveUpload(at: start.addingTimeInterval(60), bytes: 40),
      DriveUpload(at: start.addingTimeInterval(120), bytes: 10),
    ]
    let now = start.addingTimeInterval(600)
    #expect(DriveBridge.resumption(of: 10, after: uploads, limit: 100, now: now) == nil)
    #expect(
      DriveBridge.resumption(of: 20, after: uploads, limit: 100, now: now)
        == start.addingTimeInterval(86_400))
    #expect(
      DriveBridge.resumption(of: 60, after: uploads, limit: 100, now: now)
        == start.addingTimeInterval(60 + 86_400))
    #expect(
      DriveBridge.resumption(of: 200, after: uploads, limit: 100, now: now)
        == now.addingTimeInterval(86_400))
  }

  @Test func rangesAreReadAsResticSendsThem() {
    #expect(ByteRange(nil, size: 10) == ByteRange(bounds: 0..<10, isPartial: false))
    #expect(ByteRange("bytes=0-", size: 10) == ByteRange(bounds: 0..<10, isPartial: true))
    #expect(ByteRange("bytes=3-5", size: 10) == ByteRange(bounds: 3..<6, isPartial: true))
    #expect(ByteRange("bytes=3-50", size: 10) == ByteRange(bounds: 3..<10, isPartial: true))
    #expect(ByteRange("bytes=10-", size: 10) == nil)
    #expect(ByteRange("bytes=-5", size: 10) == nil)
    #expect(ByteRange("bytes=5-3", size: 10) == nil)
  }
}

/// An entry of a version 2 listing.
private struct ListedFile: Decodable, Equatable {
  var name: String
  var size: Int64
}
