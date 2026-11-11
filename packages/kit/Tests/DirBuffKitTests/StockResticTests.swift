import CryptoKit
import Foundation
import Testing

@testable import DirBuffKit

extension InMemoryDrive {
  /// Copies the folder, and everything under it, out of Drive into `directory`, as a download of
  /// it would.
  func export(_ folder: DriveFileID, to directory: URL) async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for item in try await allChildren(of: folder) {
      let target = directory.appendingPathComponent(item.name)
      if item.isFolder {
        try await export(item.id, to: target)
      } else {
        try download(item.id, range: nil).write(to: target)
      }
    }
  }
}

/// A repository DirBuff writes, read by the pinned restic exactly as `README.txt` tells a person to:
/// the README's own commands, run in a shell, against the Drive folder laid out as plain files.
/// Nothing of DirBuff's is in the read path: not `Restic`, not the bridge, not the database.
@Suite struct StockResticTests {
  let drive = InMemoryDrive(pageSize: 100)
  let macName = "Jo’s MacBook Pro"
  static let password = "correct horse battery"

  // MARK: Downloaded, then read with restic

  @Test(arguments: [nil, StockResticTests.password])
  func theReadmesCommandsListAndRestoreADownloadedBackup(password: String?) async throws {
    let backup = try await backedUp(password: password)
    let terminal = try Terminal(scratch: backup.scratch, password: password)
    let downloaded = try await terminal.download(macName, of: drive, as: "Backup")
    #expect(exists(downloaded.appendingPathComponent("config")))
    let commands = try ReadmeCommands(for: macName, password: password)

    // Step 2: list what's in it.
    let listing = try await terminal.run(commands.list)
    let snapshots = try SnapshotListing(listing)
    #expect(snapshots.ids.count == 2)
    // The path says where the folder was, and the tag names its series, as the README says.
    #expect(listing.contains("/docs"))
    #expect(snapshots.series == backup.series)

    // Step 3: a snapshot by its ID is the folder as it was then...
    let older = try await terminal.run(commands.restore(snapshots.ids[0]))
    #expect(older.contains("Summary") || older.contains("restoring"))
    #expect(try terminal.restored().contents(ofFileEndingWith: "a.txt") == "first")
    #expect(
      try terminal.restored().contents(ofFileEndingWith: "work/b.txt") == "unchanged")
    try terminal.clearRestored()

    // ... and the folder's newest, by its tag, as it is now.
    _ = try await terminal.run(commands.restoreLatest(series: snapshots.series))
    let restored = try terminal.restored()
    #expect(try restored.contents(ofFileEndingWith: "a.txt") == "second")
    #expect(try restored.contents(ofFileEndingWith: "work/b.txt") == "unchanged")
    #expect(try restored.digest(ofFileEndingWith: "photo.raw") == backup.photoDigest)
  }

  @Test func aBackupWithAPasswordIsNotOpenedByTheNoPasswordCommand() async throws {
    let backup = try await backedUp(password: Self.password)
    let terminal = try Terminal(scratch: backup.scratch, password: nil)
    _ = try await terminal.download(macName, of: drive, as: "Backup")

    await #expect(throws: Terminal.Failed.self) {
      try await terminal.run(ReadmeCommands(for: macName, password: nil).list)
    }
  }

  /// Google's zip may leave out the folders with nothing in them (the 256 shards of `data/` that
  /// hold no pack): restic must not need them to read.
  @Test func aDownloadWithoutItsEmptyFoldersStillOpens() async throws {
    let backup = try await backedUp(password: nil)
    let terminal = try Terminal(scratch: backup.scratch, password: nil)
    let downloaded = try await terminal.download(macName, of: drive, as: "Backup")
    try removeEmptyFolders(under: downloaded)
    let commands = try ReadmeCommands(for: macName, password: nil)

    let snapshots = try SnapshotListing(try await terminal.run(commands.list))
    _ = try await terminal.run(commands.restoreLatest(series: snapshots.series))
    #expect(try terminal.restored().contents(ofFileEndingWith: "a.txt") == "second")
  }

  // MARK: Read in place, through rclone

  @Test(
    .enabled(if: Terminal.rcloneOnHand || Terminal.isCI),
    arguments: [nil, StockResticTests.password])
  func theReadmesRcloneRouteReadsInPlaceAndWritesNothing(password: String?) async throws {
    let backup = try await backedUp(password: password)
    let terminal = try Terminal(scratch: backup.scratch, password: password)
    // The whole of `DirBuff Backup/`, as My Drive holds it, and rclone's `gdrive:` remote over it.
    let myDrive = try await terminal.mirrorMyDrive(of: drive)
    try terminal.useRcloneRemote(named: "gdrive", over: myDrive)
    // Nothing can be written there: a restic that took a lock, as it does without `--no-lock`,
    // would fail, so the commands below prove they only read.
    try setWritable(false, under: myDrive)
    defer { try? setWritable(true, under: myDrive) }
    let before = try TreeDigest(of: myDrive)
    #expect(before.paths.contains("DirBuff Backup/README.txt"))
    let commands = try ReadmeCommands(for: macName, password: password)

    let listing = try await terminal.run(commands.rcloneList)
    let snapshots = try SnapshotListing(listing)
    #expect(snapshots.ids.count == 2)
    _ = try await terminal.run(commands.rcloneRestore(snapshots.ids[1]))
    #expect(try terminal.restored().contents(ofFileEndingWith: "a.txt") == "second")
    #expect(
      try terminal.restored().digest(ofFileEndingWith: "photo.raw") == backup.photoDigest)

    #expect(try TreeDigest(of: myDrive) == before)
  }

  // MARK: Setup

  struct BackedUp {
    let scratch: Scratch
    let folder: URL
    /// The folder's series: the tag is `folder=<series>`.
    let series: String
    let photoDigest: String
  }

  /// One Mac backs a folder up twice into the Drive, as the app does, and then goes away.
  private func backedUp(password: String?) async throws -> BackedUp {
    let mac = try DriveMac(macName, host: "mac-a", drive: drive)
    let folderID = try mac.addWearing("docs")
    try mac.scratch.folder("docs/work")
    try mac.write("first", to: "docs/a.txt")
    try mac.write("unchanged", to: "docs/work/b.txt")
    // Enough that never compresses to make a pack of its own.
    let photo = randomData(2_000_000)
    try photo.write(to: mac.scratch.url.appendingPathComponent("docs/photo.raw"))
    try await mac.run(folderID)
    if let password { try await mac.backup.setPassword(password) }
    try mac.write("second", to: "docs/a.txt")
    try await mac.run(folderID)
    return BackedUp(
      scratch: mac.scratch, folder: mac.scratch.url.appendingPathComponent("docs"),
      series: String(try mac.record(folderID).resticTag.dropFirst("folder=".count)),
      photoDigest: SHA256.hash(data: photo).hex)
  }

  private func setWritable(_ writable: Bool, under root: URL) throws {
    let fileManager = FileManager.default
    let found =
      [root]
      + (fileManager.enumerator(at: root, includingPropertiesForKeys: nil)?
        .allObjects.compactMap { $0 as? URL } ?? [])
    for url in found {
      let isFolder = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
      let mode: Int = isFolder ? (writable ? 0o755 : 0o555) : (writable ? 0o644 : 0o444)
      try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
  }

  private func removeEmptyFolders(under root: URL) throws {
    let fileManager = FileManager.default
    var removed = true
    while removed {
      removed = false
      let folders =
        fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])?
        .allObjects.compactMap { $0 as? URL } ?? []
      for folder in folders {
        let isFolder = try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        guard isFolder, try fileManager.contentsOfDirectory(atPath: folder.path).isEmpty else {
          continue
        }
        try fileManager.removeItem(at: folder)
        removed = true
      }
    }
  }
}

// MARK: - The person at the terminal

/// What `README.txt` says to type, taken from the README itself, with the placeholders filled in.
struct ReadmeCommands {
  let list: String
  private let restoreByID: String
  private let restoreNewest: String
  let rcloneList: String
  private let rcloneRestoreByID: String

  /// With a password, as the README says: the commands without `--insecure-no-password`.
  init(for macName: String, password: String?) throws {
    let all = Self.commands(in: BackupReadme.text).map {
      password == nil ? $0 : $0.replacing(" --insecure-no-password", with: "")
    }
    func one(_ matching: (String) -> Bool) throws -> String {
      let found = all.filter(matching)
      guard found.count == 1, let command = found.first else {
        throw ReadmeChanged(
          "README.txt has \(found.count) commands where the test expects 1: \(found)")
      }
      return command
    }
    func isRclone(_ command: String) -> Bool { command.contains("rclone:") }
    list = try one { !isRclone($0) && $0.hasSuffix(" snapshots") }
    restoreByID = try one { !isRclone($0) && $0.contains("restore <ID>") }
    restoreNewest = try one { !isRclone($0) && $0.contains("restore latest") }
    rcloneList = try one { isRclone($0) && $0.hasSuffix(" snapshots") }.replacing(
      "<Mac>", with: macName)
    rcloneRestoreByID = try one { isRclone($0) && $0.contains("restore <ID>") }.replacing(
      "<Mac>", with: macName)
  }

  func restore(_ id: String) -> String { restoreByID.replacing("<ID>", with: id) }
  func restoreLatest(series: String) -> String {
    restoreNewest.replacing("<...>", with: series)
  }
  func rcloneRestore(_ id: String) -> String { rcloneRestoreByID.replacing("<ID>", with: id) }

  struct ReadmeChanged: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  /// Every command the README shows, from `restic` to the end of its last continued line.
  private static func commands(in text: String) -> [String] {
    var commands: [String] = []
    var current: String?
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if var command = current {
        command += " " + trimmed
        current = command
      } else if trimmed.hasPrefix("restic -r ") {
        current = trimmed
      } else {
        continue
      }
      if let command = current, command.hasSuffix("\\") {
        current = String(command.dropLast()).trimmingCharacters(in: .whitespaces)
      } else if let command = current {
        commands.append(command.replacing("  ", with: " "))
        current = nil
      }
    }
    return commands
  }
}

/// `restic snapshots`' table, as a person reads it.
struct SnapshotListing {
  /// Snapshot IDs, oldest first, as the table lists them.
  let ids: [String]
  /// The folder's series: what follows `folder=` in the tag every row carries.
  let series: String

  init(_ output: String) throws {
    ids = output.split(separator: "\n").compactMap { line in
      let first = line.split(separator: " ").first.map(String.init) ?? ""
      return first.count == 8 && first.allSatisfy({ "0123456789abcdef".contains($0) }) ? first : nil
    }
    let tags = Set(
      output.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("folder=") }.map(
        String.init))
    guard tags.count == 1, let tag = tags.first else {
      throw Terminal.Failed(output: "no single folder=… tag in the listing:\n\(output)")
    }
    self.series = String(tag.dropFirst("folder=".count))
  }
}

/// A shell with the pinned, unmodified restic on its path, and a home of its own. Every command
/// is a README line, run as typed, with `~` for that home.
struct Terminal {
  struct Failed: Error, CustomStringConvertible {
    let output: String
    var description: String { output }
  }

  struct MissingRclone: Error, CustomStringConvertible {
    var description: String {
      "The rclone route is tested in CI, which has rclone: brew install rclone."
    }
  }

  let home: URL
  private let bin: URL
  private let environment: [String: String]
  private let rclone: URL?

  static var isCI: Bool { ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" }
  static var rcloneOnHand: Bool { findRclone() != nil }

  init(scratch: Scratch, password: String?) throws {
    home = try scratch.folder("terminal/home")
    bin = try scratch.folder("terminal/bin")
    try FileManager.default.createSymbolicLink(
      at: bin.appendingPathComponent("restic"), withDestinationURL: resticExecutable())
    rclone = Self.findRclone()
    if let rclone {
      try FileManager.default.createSymbolicLink(
        at: bin.appendingPathComponent("rclone"), withDestinationURL: rclone)
    }
    var environment = [
      "HOME": home.path,
      "PATH": "\(bin.path):/usr/bin:/bin",
      "RESTIC_CACHE_DIR": home.appendingPathComponent("cache").path,
      "RCLONE_CONFIG": home.appendingPathComponent("rclone.conf").path,
    ]
    // What a person types when restic asks: no terminal here to ask on.
    if let password { environment["RESTIC_PASSWORD"] = password }
    self.environment = environment
  }

  private static func findRclone() -> URL? {
    let path = ProcessInfo.processInfo.environment["PATH", default: ""]
    return (path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"])
      .map { URL(fileURLWithPath: $0).appendingPathComponent("rclone") }
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  // MARK: Getting the files

  /// Step 1: the Mac's folder out of Drive and into `~/<name>`.
  func download(_ macName: String, of drive: InMemoryDrive, as name: String) async throws -> URL {
    let mac = try #require(
      try await drive.allCreated().first { $0.name == macName && $0.isFolder })
    let folder = home.appendingPathComponent(name)
    try await drive.export(mac.id, to: folder)
    return folder
  }

  /// All of `DirBuff Backup/` in a folder standing for My Drive.
  func mirrorMyDrive(of drive: InMemoryDrive) async throws -> URL {
    let backups = try #require(
      try await drive.allCreated().first { $0.name == "DirBuff Backup" && $0.isFolder })
    let myDrive = home.deletingLastPathComponent().appendingPathComponent("my-drive")
    try await drive.export(backups.id, to: myDrive.appendingPathComponent("DirBuff Backup"))
    return myDrive
  }

  /// The user's rclone remote for their Google account, here a folder.
  func useRcloneRemote(named name: String, over folder: URL) throws {
    guard rclone != nil else { throw MissingRclone() }
    try "[\(name)]\ntype = alias\nremote = \(folder.path)\n".write(
      to: home.appendingPathComponent("rclone.conf"), atomically: true, encoding: .utf8)
  }

  // MARK: Running and reading

  /// Runs `command` in a shell as typed; its output, or `Failed` when it ends in error.
  @discardableResult
  func run(_ command: String) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = environment
    process.currentDirectoryURL = home
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    try process.run()
    // A restic that can't write retries for minutes: end it, so the test fails and doesn't hang.
    let timeout = Task {
      try await Task.sleep(for: .seconds(90))
      process.terminate()
    }
    defer { timeout.cancel() }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard process.terminationStatus == 0 else {
      throw Failed(output: "`\(command)` ended with \(process.terminationStatus):\n\(text)")
    }
    return text
  }

  /// What is in `~/Restored`.
  func restored() throws -> RestoredFiles {
    try RestoredFiles(root: home.appendingPathComponent("Restored"))
  }

  func clearRestored() throws {
    try FileManager.default.removeItem(at: home.appendingPathComponent("Restored"))
  }
}

struct RestoredFiles {
  private let files: [String: URL]

  init(root: URL) throws {
    let root = root.resolvingSymlinksInPath()
    var files: [String: URL] = [:]
    let found =
      FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects
      .compactMap { $0 as? URL } ?? []
    for url in found
    where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      files[String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count))] = url
    }
    self.files = files
  }

  private func file(endingWith suffix: String) throws -> URL {
    let matches = files.filter { $0.key.hasSuffix("/" + suffix) }
    guard matches.count == 1, let url = matches.first?.value else {
      throw Terminal.Failed(
        output: "\(matches.count) restored files end in \(suffix), among \(files.keys.sorted())")
    }
    return url
  }

  func contents(ofFileEndingWith suffix: String) throws -> String {
    try String(contentsOf: file(endingWith: suffix), encoding: .utf8)
  }

  func digest(ofFileEndingWith suffix: String) throws -> String {
    SHA256.hash(data: try Data(contentsOf: file(endingWith: suffix))).hex
  }
}

/// Every folder and file under a folder, each file with its bytes' hash.
struct TreeDigest: Equatable {
  private let entries: [String: String]
  var paths: Set<String> { Set(entries.keys) }

  init(of root: URL) throws {
    let root = root.resolvingSymlinksInPath()
    var entries: [String: String] = [:]
    let found =
      FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey])?.allObjects
      .compactMap { $0 as? URL } ?? []
    for url in found {
      let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
      entries[path] =
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        ? "folder" : SHA256.hash(data: try Data(contentsOf: url)).hex
    }
    self.entries = entries
  }
}

extension Digest {
  fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}
