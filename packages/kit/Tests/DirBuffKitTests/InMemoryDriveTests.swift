import Foundation
import Testing

@testable import DirBuffKit

/// The fake keeps the Drive habits the code on top of it relies on, so those are pinned here.
@Suite struct InMemoryDriveTests {
  @Test func uploadsComeBackWithTheirChecksumAndAreReadByRange() async throws {
    let drive = InMemoryDrive()
    let folder = try await drive.createFolder(named: "repo", in: nil)
    let file = try await drive.upload(Data("0123456789".utf8), named: "pack", in: folder.id)
    #expect(file.size == 10)
    #expect(file.parents == [folder.id])
    #expect(file.sha256Checksum?.count == 64)
    #expect(try await drive.download(file.id, range: 2..<5) == Data("234".utf8))
    #expect(try await drive.download(file.id, range: 8..<99) == Data("89".utf8))
    #expect(try await drive.download(file.id, range: 20..<30).isEmpty)
    #expect(try await drive.download(file.id, range: nil) == Data("0123456789".utf8))
  }

  @Test func namesAreNotUnique() async throws {
    let drive = InMemoryDrive()
    let folder = try await drive.createFolder(named: "repo", in: nil)
    let first = try await drive.upload(Data("a".utf8), named: "same", in: folder.id)
    let second = try await drive.upload(Data("b".utf8), named: "same", in: folder.id)
    #expect(first.id != second.id)
    #expect(try await drive.allChildren(of: folder.id).count == 2)
  }

  @Test func listingsComeInPagesAndSkipTheBin() async throws {
    let drive = InMemoryDrive(pageSize: 2)
    let folder = try await drive.createFolder(named: "repo", in: nil)
    var ids: [DriveFileID] = []
    for number in 0..<5 {
      ids.append(
        try await drive.upload(Data([UInt8(number)]), named: "p\(number)", in: folder.id).id)
    }
    let firstPage = try await drive.children(of: folder.id, after: nil)
    #expect(firstPage.items.count == 2)
    #expect(firstPage.nextPageToken != nil)
    #expect(try await drive.allChildren(of: folder.id).map(\.id) == ids)

    await drive.trash(ids[1])
    #expect(
      try await drive.allChildren(of: folder.id).map(\.id) == [ids[0], ids[2], ids[3], ids[4]])
    #expect(try await drive.allCreated().count == 5)  // the folder and four files
    #expect(try await drive.metadata(of: ids[1]).isTrashed)
  }

  @Test func trashingAFolderTrashesItsContentsAndUntrashingBringsThemBack() async throws {
    let drive = InMemoryDrive()
    let folder = try await drive.createFolder(named: "repo", in: nil)
    let file = try await drive.upload(Data("a".utf8), named: "p", in: folder.id)
    await drive.trash(folder.id)
    #expect(try await drive.metadata(of: file.id).isTrashed)
    #expect(try await drive.allCreated().isEmpty)
    #expect(try await !drive.untrash(folder.id).isTrashed)
    #expect(try await !drive.metadata(of: file.id).isTrashed)
  }

  @Test func deletingIsForGoodAndTakesAFoldersContentsWithIt() async throws {
    let drive = InMemoryDrive()
    let folder = try await drive.createFolder(named: "repo", in: nil)
    let file = try await drive.upload(Data("a".utf8), named: "p", in: folder.id)
    try await drive.delete(folder.id)
    await #expect(throws: DriveProblem.notFound) { try await drive.metadata(of: file.id) }
    await #expect(throws: DriveProblem.notFound) { try await drive.delete(folder.id) }
    #expect(await drive.itemCount == 0)
  }

  @Test func missingFoldersAreNotFound() async throws {
    let drive = InMemoryDrive()
    await #expect(throws: DriveProblem.notFound) {
      try await drive.upload(Data("a".utf8), named: "p", in: "nowhere")
    }
    await #expect(throws: DriveProblem.notFound) {
      try await drive.children(of: "nowhere", after: nil)
    }
  }

  @Test func theAccountRunsOutOfRoom() async throws {
    let drive = InMemoryDrive(limitBytes: 10)
    let folder = try await drive.createFolder(named: "repo", in: nil)
    _ = try await drive.upload(Data(count: 8), named: "a", in: folder.id)
    await #expect(throws: DriveProblem.storageFull) {
      try await drive.upload(Data(count: 3), named: "b", in: folder.id)
    }
    let about = try await drive.about()
    #expect(about.freeBytes == 2)
  }

  @Test func aFailureIsPlayedOnceAndTheCallsAreCounted() async throws {
    let drive = InMemoryDrive()
    await drive.failNextCall(with: .signedOut)
    await #expect(throws: DriveProblem.signedOut) { try await drive.about() }
    _ = try await drive.about()
    #expect(await drive.calls == ["about", "about"])
  }
}
