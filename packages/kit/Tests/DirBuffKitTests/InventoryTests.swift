import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

@Suite struct InventoryTests {
  let scratch: Scratch
  /// Later than any date added the tests can produce, so set modified dates decide freshness.
  let future = Date().addingTimeInterval(10 * day)

  init() throws {
    scratch = try Scratch()
  }

  private func item(_ name: String) throws -> Item {
    try #require(Inventory.items(in: scratch.url).first { $0.url.lastPathComponent == name })
  }

  @Test func datesAFileByTheLaterOfAddedAndModified() throws {
    try scratch.file("edited", modified: future)
    try scratch.file("untouched", modified: Date(timeIntervalSince1970: 0))
    #expect(try item("edited").freshness == future)
    // Date added is the moment it was written here, not 1970.
    #expect(try #require(item("untouched").freshness) > Date().addingTimeInterval(-day))
  }

  @Test func skipsHiddenItems() throws {
    try scratch.file(".DS_Store")
    try scratch.file("._photo.jpg")
    let flagged = try scratch.file("flagged")
    var values = URLResourceValues()
    values.isHidden = true
    var url = flagged
    try url.setResourceValues(values)
    try scratch.file("visible")
    #expect(try Inventory.items(in: scratch.url).map(\.url.lastPathComponent) == ["visible"])
  }

  @Test func datesAFolderByTheNewestThingInside() throws {
    try scratch.file("project/src/main.swift", modified: future)
    try scratch.file("project/notes.txt")
    #expect(try item("project").freshness == future)
  }

  @Test func ignoresAFoldersOwnModifiedDateAndItsHiddenFiles() throws {
    try scratch.file("project/notes.txt")
    try scratch.file("project/.DS_Store", modified: future)
    try scratch.file("project/.git/HEAD", modified: future)
    try setModified(future, of: scratch.url.appendingPathComponent("project"))
    #expect(try #require(item("project").freshness) < future)
  }

  @Test func leavesAFolderUndatedWhenPartOfItCantBeRead() throws {
    try scratch.file("project/notes.txt")
    let locked = try scratch.folder("project/locked")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }
    #expect(try item("project").freshness == nil)
  }

  @Test func treatsAPackageAsOneItem() throws {
    try scratch.file("Tool.app/Contents/MacOS/Tool", bytes: 100_000, modified: future)
    let items = try Inventory.items(in: scratch.url)
    #expect(items.map(\.url.lastPathComponent) == ["Tool.app"])
    #expect(try #require(items.first?.freshness) < future)
    #expect(try #require(items.first?.size) >= 100_000)
  }

  @Test func sizesAFolderWithEverythingInside() throws {
    try scratch.file("project/a", bytes: 50_000)
    try scratch.file("project/.cache/b", bytes: 50_000)
    #expect(try item("project").size >= 100_000)
  }
}
