import Darwin
import DirBuffCore
import Foundation
import Testing

@testable import DirBuffKit

/// The bulk walk against the `fts` walk it replaced, and the two flags it reads.
@Suite struct ExclusionsWalkTests {
  private static let names: Set = ["node_modules", ".git", "extra"]

  @Test func theBulkWalkFindsWhatTheFtsWalkDid() throws {
    let scratch = try Scratch()
    let root = try canonicalPath(of: scratch.folder("folder"))
    defer { Self.restorePermissions(in: root) }
    let found = try Self.makeTreeWithEveryCase(in: root)
    let paths: Set = [root + "/left/out", root + "/person/Library", root + "/own"]

    let bulk = Exclusions.walk(root, skippingNames: Self.names, skippingPaths: paths)
    let fts = FtsExclusionsWalk.walk(root, skippingNames: Self.names, skippingPaths: paths)

    #expect(bulk.timeMachineExcluded.sorted() == fts.timeMachineExcluded.sorted())
    #expect(bulk.cloudOnly == fts.cloudOnly)
    // Not agreeing on nothing: both found exactly the entries that carry the attribute and aren't
    // left out, inside a folder that was left out, or inside one that was found.
    #expect(bulk.timeMachineExcluded.sorted() == found.map { root + "/" + $0 }.sorted())
  }

  @Test func anEntryIsCloudOnlyWhenItsFlagsSayDataless() {
    func entry(flags: UInt32) -> Exclusions.Entry {
      Exclusions.Entry(name: "a", isFolder: false, flags: flags, extendedFlags: nil)
    }
    #expect(entry(flags: UInt32(SF_DATALESS)).isCloudOnly)
    #expect(entry(flags: UInt32(SF_DATALESS) | UInt32(UF_HIDDEN)).isCloudOnly)
    #expect(!entry(flags: UInt32(UF_HIDDEN)).isCloudOnly)
    #expect(!entry(flags: 0).isCloudOnly)
  }

  @Test func anEntryHasNoAttributesOnlyWhenTheVolumeSaysSo() {
    func entry(extendedFlags: UInt32?) -> Exclusions.Entry {
      Exclusions.Entry(name: "a", isFolder: false, flags: 0, extendedFlags: extendedFlags)
    }
    #expect(!entry(extendedFlags: UInt32(EF_NO_XATTRS)).mayHaveExtendedAttributes)
    #expect(
      !entry(extendedFlags: UInt32(EF_NO_XATTRS) | UInt32(EF_IS_SPARSE)).mayHaveExtendedAttributes)
    #expect(entry(extendedFlags: 0).mayHaveExtendedAttributes)
    #expect(entry(extendedFlags: UInt32(EF_IS_SPARSE)).mayHaveExtendedAttributes)
    #expect(entry(extendedFlags: nil).mayHaveExtendedAttributes)
  }

  @Test func theListingNeverSaysAnEntryWithAnAttributeHasNone() throws {
    let scratch = try Scratch()
    try scratch.file("plain")
    try scratch.file("marked")
    try scratch.file("other")
    try scratch.folder("folder")
    try Self.setAttribute(
      BackupDefaults.timeMachineExclusionAttribute, on: scratch.url.path + "/marked")
    try Self.setAttribute("com.apple.provenance", on: scratch.url.path + "/other")
    try Self.setAttribute(
      BackupDefaults.timeMachineExclusionAttribute, on: scratch.url.path + "/folder")
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Exclusions.listingSize, alignment: 8)
    defer { buffer.deallocate() }

    let entries = Dictionary(
      uniqueKeysWithValues: Exclusions.entries(in: scratch.url.path, buffer: buffer).map {
        ($0.name, $0)
      })

    #expect(entries.count == 4)
    #expect(entries["folder"]?.isFolder == true)
    #expect(entries["plain"]?.isFolder == false)
    #expect(entries["marked"]?.mayHaveExtendedAttributes == true)
    #expect(entries["other"]?.mayHaveExtendedAttributes == true)
    #expect(entries["folder"]?.mayHaveExtendedAttributes == true)
  }

  @Test func aRecordWithoutTheTypeOrFlagsIsReadWithAnLstat() throws {
    let scratch = try Scratch()
    try scratch.file("file")
    try scratch.folder("folder")
    func record(for name: String) -> [UInt8] {
      let name = Array(name.utf8) + [0]
      var bytes: [UInt8] = []
      func append<Value>(_ value: Value) { withUnsafeBytes(of: value) { bytes += $0 } }
      append(
        UInt32(
          MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
            + MemoryLayout<attrreference_t>.size + name.count))
      append(
        attribute_set_t(
          commonattr: ATTR_CMN_RETURNED_ATTRS | attrgroup_t(ATTR_CMN_NAME), volattr: 0, dirattr: 0,
          fileattr: 0, forkattr: 0))
      append(
        attrreference_t(
          attr_dataoffset: Int32(MemoryLayout<attrreference_t>.size),
          attr_length: UInt32(name.count)))
      return bytes + name
    }
    func entry(for name: String) throws -> Exclusions.Entry? {
      try record(for: name).withUnsafeBytes { bytes in
        Exclusions.entry(at: try #require(bytes.baseAddress), in: scratch.url.path)
      }
    }

    #expect(
      try entry(for: "file") == Exclusions.Entry(name: "file", isFolder: false, flags: 0))
    #expect(
      try entry(for: "folder") == Exclusions.Entry(name: "folder", isFolder: true, flags: 0))
    #expect(try entry(for: "gone") == nil)
  }

  /// Walks a real folder both ways, a few times, and times them: only with
  /// DIRBUFF_MEASURE_WALK=<folder>. The two must find the same.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRBUFF_MEASURE_WALK"] != nil))
  func measureTheWalks() throws {
    let environment = ProcessInfo.processInfo.environment
    let folder = try canonicalPath(
      of: URL(fileURLWithPath: try #require(environment["DIRBUFF_MEASURE_WALK"])))
    for round in 1...(Int(environment["DIRBUFF_MEASURE_ROUNDS"] ?? "") ?? 5) {
      let clock = ContinuousClock()
      var bulk: (timeMachineExcluded: [String], cloudOnly: [String]) = ([], [])
      var fts = bulk
      let bulkTime = clock.measure {
        bulk = Exclusions.walk(folder, skippingNames: [], skippingPaths: [])
      }
      let ftsTime = clock.measure {
        fts = FtsExclusionsWalk.walk(folder, skippingNames: [], skippingPaths: [])
      }
      var loads = [Double](repeating: 0, count: 3)
      _ = getloadavg(&loads, 3)
      print(
        "measure: round \(round): bulk \(bulkTime), fts \(ftsTime), load \(loads[0]), "
          + "found \(bulk.timeMachineExcluded.count) excluded, \(bulk.cloudOnly.count) cloud-only")
      #expect(bulk.timeMachineExcluded.sorted() == fts.timeMachineExcluded.sorted())
      #expect(bulk.cloudOnly.sorted() == fts.cloudOnly.sorted())
    }
  }

  private static func setAttribute(_ name: String, on path: String) throws {
    guard setxattr(path, name, "x", 1, 0, XATTR_NOFOLLOW) == 0 else {
      throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
  }

  private static func restorePermissions(in root: String) {
    for name in ["locked", "marked-locked"] { chmod(root + "/" + name, 0o700) }
  }

  /// Fills `root` with every kind of entry the walk meets. Returns the paths, under `root`, that
  /// the walk must find: those with Time Machine's attribute that nothing else leaves out.
  private static func makeTreeWithEveryCase(in root: String) throws -> [String] {
    let excluded = BackupDefaults.timeMachineExclusionAttribute
    let cacheTag = BackupDefaults.cacheDirectorySignature + "\n# a cache\n"
    var found: [String] = []
    func make(_ path: String, contents: String = "x") throws {
      let file = URL(fileURLWithPath: root + "/" + path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: file, atomically: false, encoding: .utf8)
    }
    func mark(_ path: String) throws { try setAttribute(excluded, on: root + "/" + path) }
    func makeFound(_ path: String) throws {
      try make(path)
      try mark(path)
      found.append(path)
    }
    func makeLink(_ path: String, to destination: String) throws {
      try FileManager.default.createSymbolicLink(
        atPath: root + "/" + path, withDestinationPath: destination)
    }

    // Plain entries, deep and awkwardly named.
    for path in [
      "kept.txt", "a/b/c/d/e/deep.txt", "spaced name/file with spaces.txt", "caf\u{e9}/\u{e9}.txt",
      "stars*[x]?/$HOME/#note.txt", "target/kept.db",
    ] {
      try make(path)
    }
    try FileManager.default.createDirectory(
      atPath: root + "/empty", withIntermediateDirectories: true)

    // Time Machine's attribute on a file, a folder (its contents are not looked at), a link, a
    // dangling link and a fifo. Another attribute doesn't count.
    for path in [
      "marked.db", "a/b/marked.db", "spaced name/marked.db", "caf\u{e9}/marked \u{e9}.db",
      "stars*[x]?/$HOME/#marked.db", "Thing.app/Contents/Resources/marked.icns",
      "not-a-cache/data.db",
    ] {
      try makeFound(path)
    }
    try make("marked folder/inside.db")
    try mark("marked folder/inside.db")
    try mark("marked folder")
    found.append("marked folder")
    // Another attribute doesn't count, however many there are, and nor does a name that only
    // contains Time Machine's.
    try make("other-attribute.db")
    try setAttribute("com.apple.provenance", on: root + "/other-attribute.db")
    try make("other-attributes.db")
    for name in ["com.apple.provenance", "com.apple.quarantine", "com.apple.lastuseddate#PS"] {
      try setAttribute(name, on: root + "/other-attributes.db")
    }
    try make("lookalike.db")
    for name in [excluded + "2", "x" + excluded, String(excluded.dropLast())] {
      try setAttribute(name, on: root + "/lookalike.db")
    }
    // Time Machine's among others, anywhere in the list.
    for (index, name) in ["a", "z"].enumerated() {
      let path = "among-others-\(name).db"
      try make(path)
      try setAttribute("com.apple.provenance", on: root + "/" + path)
      if index == 1 { try mark(path) }
      for other in ["com.apple.quarantine", "com.apple.lastuseddate#PS"] {
        try setAttribute(other, on: root + "/" + path)
      }
      if index == 0 { try mark(path) }
      found.append(path)
    }
    try makeLink("link-to-target", to: "target")
    try mark("target/kept.db")
    found.append("target/kept.db")
    try makeLink("marked-link", to: "kept.txt")
    try mark("marked-link")
    found.append("marked-link")
    try makeLink("dangling", to: "nowhere")
    try mark("dangling")
    found.append("dangling")
    for name in ["fifo", "marked-fifo"] {
      guard mkfifo(root + "/" + name, 0o600) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
      }
    }
    try mark("marked-fifo")
    found.append("marked-fifo")

    // A folder whose CACHEDIR.TAG begins with the signature is left out whole, even when it also
    // has the attribute; a tag without the signature doesn't count.
    try make("cache/data.db")
    try make("cache/CACHEDIR.TAG", contents: cacheTag)
    try mark("cache/data.db")
    try make("cache-and-marked/CACHEDIR.TAG", contents: cacheTag)
    try mark("cache-and-marked")
    try make("a/b/nested-cache/CACHEDIR.TAG", contents: cacheTag)
    try make("a/b/nested-cache/data.db")
    try mark("a/b/nested-cache/data.db")
    try make("not-a-cache/CACHEDIR.TAG", contents: "just a file")

    // What is left out by name (a file with a left-out name is not) or by path is never looked into.
    for path in [
      "node_modules/x.db", "a/.git/x.db", "extra/x.db", "left/out/x.db", "person/Library/x.db",
      "own/x.db",
    ] {
      try make(path)
      try mark(path)
    }
    for path in ["node_modules", "a/.git", "own"] { try mark(path) }
    try makeFound("a/extra")
    try makeFound("person/Documents/x.db")
    try make("left/other.db")

    // A folder that can't be read is neither looked into nor asked for its attributes.
    try make("locked/inside.db")
    try make("marked-locked/inside.db")
    try mark("marked-locked")
    chmod(root + "/locked", 0)
    chmod(root + "/marked-locked", 0)

    // A folder longer than one read of the listing, with the attribute here and there.
    for index in 0..<3_000 {
      let path = "many/\(String(repeating: "n", count: 80))-\(index).bin"
      if index % 701 == 0 { try makeFound(path) } else { try make(path) }
    }
    return found
  }
}
