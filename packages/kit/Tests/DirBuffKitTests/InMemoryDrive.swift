import CryptoKit
import Foundation

@testable import DirBuffKit

/// Drive in memory, for tests of what is built on `DriveFiles`. It keeps Drive's habits that
/// matter to a caller: names aren't unique, listings come in pages and leave out the Bin, trashing
/// a folder trashes what is in it, and deleting is for good.
actor InMemoryDrive: DriveFiles {
  struct Stored {
    var item: DriveItem
    var data: Data
    var order: Int
  }

  let email: String
  /// Items a page lists; small by default so a test of paging needs few files.
  var pageSize: Int
  /// Bytes the account may hold (Drive's room), or nil for no limit.
  var limitBytes: Int64?
  /// When set, the next call throws this instead of running (once).
  private var pendingFailure: DriveProblem?
  /// Every call made, by name, in order.
  private(set) var calls: [String] = []

  private var files: [DriveFileID: Stored] = [:]
  private var created = 0

  init(email: String = "jo@example.com", pageSize: Int = 3, limitBytes: Int64? = nil) {
    self.email = email
    self.pageSize = pageSize
    self.limitBytes = limitBytes
  }

  // MARK: Setting up and playing the user

  func failNextCall(with problem: DriveProblem) { pendingFailure = problem }

  /// The user puts the file, and what is in it, in the Bin.
  func trash(_ id: DriveFileID) { setTrashed(true, id) }

  /// The user empties the Bin, or deletes the file in Drive's own page.
  func remove(_ id: DriveFileID) { removeTree(id) }

  /// The bytes a file holds, for a test to compare.
  func contents(of id: DriveFileID) -> Data? { files[id]?.data }

  var itemCount: Int { files.count }
  var usedBytes: Int64 { files.values.reduce(0) { $0 + Int64($1.data.count) } }

  func clearCalls() { calls = [] }

  // MARK: DriveFiles

  func about() throws -> DriveAbout {
    try begin("about")
    return DriveAbout(email: email, usedBytes: usedBytes, limitBytes: limitBytes)
  }

  func createFolder(named name: String, in parent: DriveFileID?) throws -> DriveItem {
    try begin("createFolder")
    if let parent { try requireFolder(parent) }
    return add(
      name: name, mimeType: DriveItem.folderMimeType, parent: parent, data: Data()
    ).item
  }

  func children(of folder: DriveFileID, after pageToken: String?) throws -> DrivePage {
    try begin("children")
    try requireFolder(folder)
    return page(of: files.values.filter { $0.item.parents == [folder] }, after: pageToken)
  }

  func created(after pageToken: String?) throws -> DrivePage {
    try begin("created")
    return page(of: Array(files.values), after: pageToken)
  }

  func metadata(of id: DriveFileID) throws -> DriveItem {
    try begin("metadata")
    return try stored(id).item
  }

  func upload(_ data: Data, named name: String, in folder: DriveFileID) throws -> DriveItem {
    try begin("upload")
    try requireFolder(folder)
    if let limitBytes, usedBytes + Int64(data.count) > limitBytes { throw DriveProblem.storageFull }
    return add(name: name, mimeType: "application/octet-stream", parent: folder, data: data).item
  }

  func download(_ id: DriveFileID, range: Range<Int64>?) throws -> Data {
    try begin("download")
    let data = try stored(id).data
    guard let range else { return data }
    let end = min(Int(range.upperBound), data.count)
    guard Int(range.lowerBound) < end else { return Data() }
    return Data(data[Int(range.lowerBound)..<end])
  }

  func delete(_ id: DriveFileID) throws {
    try begin("delete")
    _ = try stored(id)
    removeTree(id)
  }

  func untrash(_ id: DriveFileID) throws -> DriveItem {
    try begin("untrash")
    _ = try stored(id)
    setTrashed(false, id)
    return try stored(id).item
  }

  // MARK: Inside

  private func begin(_ call: String) throws {
    calls.append(call)
    if let failure = pendingFailure {
      pendingFailure = nil
      throw failure
    }
  }

  private func stored(_ id: DriveFileID) throws -> Stored {
    guard let stored = files[id] else { throw DriveProblem.notFound }
    return stored
  }

  private func requireFolder(_ id: DriveFileID) throws {
    guard try stored(id).item.isFolder else { throw DriveProblem.notFound }
  }

  private func add(name: String, mimeType: String, parent: DriveFileID?, data: Data) -> Stored {
    created += 1
    let id = DriveFileID("fake-\(created)")
    let isFolder = mimeType == DriveItem.folderMimeType
    let item = DriveItem(
      id: id, name: name, mimeType: mimeType, size: isFolder ? nil : Int64(data.count),
      parents: parent.map { [$0] } ?? [],
      sha256Checksum: isFolder
        ? nil : SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    let stored = Stored(item: item, data: data, order: created)
    files[id] = stored
    return stored
  }

  private func page(of candidates: [Stored], after token: String?) -> DrivePage {
    let live = candidates.filter { !$0.item.isTrashed }.sorted { $0.order < $1.order }
    let start = token.flatMap { Int($0) } ?? 0
    let items = live.dropFirst(start).prefix(pageSize).map(\.item)
    let next = start + pageSize
    return DrivePage(items: Array(items), nextPageToken: next < live.count ? String(next) : nil)
  }

  private func descendants(of id: DriveFileID) -> [DriveFileID] {
    let children = files.values.filter { $0.item.parents == [id] }.map(\.item.id)
    return [id] + children.flatMap(descendants(of:))
  }

  private func setTrashed(_ isTrashed: Bool, _ id: DriveFileID) {
    for member in descendants(of: id) { files[member]?.item.isTrashed = isTrashed }
  }

  private func removeTree(_ id: DriveFileID) {
    for member in descendants(of: id) { files[member] = nil }
  }
}
