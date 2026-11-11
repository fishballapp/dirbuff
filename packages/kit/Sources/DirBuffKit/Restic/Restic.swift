import Foundation

/// The restic binary in the app bundle, driving one repository.
///
/// Every command runs with `--json`, at utility priority on two cores, with the password on
/// its standard input, and is stopped when it stalls. `repository` is anything restic takes for
/// `-r`: a folder, or the REST address of the Drive bridge.
public struct Restic: Sendable {
  /// `backup` and `restore` are stopped when nothing moves for this long. restic's counters stand
  /// still while a pack crawls up a slow uplink to Drive, so this is generous.
  public static let defaultStallLimit = StallLimit.noProgress(for: .seconds(1800))

  /// The quick commands (`init`, `snapshots`, `forget`) are stopped after this long.
  public static let defaultWallClockLimit = Duration.seconds(600)

  /// Below what the user is doing (`qualityOfService`).
  public static let defaultQualityOfService = QualityOfService.utility

  public var executable: URL
  public var repository: String
  /// Nil for a repository that opens with no password (`--insecure-no-password`). Must not start
  /// or end with whitespace: restic trims it.
  public var password: String?
  /// Where restic keeps its cache of the repository's index; its own default when nil.
  public var cacheDirectory: URL?
  public var terminationGrace: Duration
  /// Utility: below what the user is doing, on two cores. Background would hand restic the
  /// efficiency cores and little of them while other work runs, and on a busy Mac a backup at
  /// that priority may never finish (opening the repository alone took up to 95 s at a load of 50).
  public var qualityOfService: QualityOfService
  /// How long restic waits on a request to a REST repository that neither sends nor answers
  /// before it gives up on it; restic's own 5 minutes when nil.
  public var stuckRequestTimeout: Duration?
  /// How many requests restic makes at once to a REST repository; restic's own 5 when nil.
  public var restConnections: Int?

  public init(
    executable: URL, repository: String, password: String?, cacheDirectory: URL? = nil,
    terminationGrace: Duration = .seconds(30),
    qualityOfService: QualityOfService = defaultQualityOfService
  ) {
    self.executable = executable
    self.repository = repository
    self.password = password
    self.cacheDirectory = cacheDirectory
    self.terminationGrace = terminationGrace
    self.qualityOfService = qualityOfService
  }

  /// The executable in `Contents/Helpers` of the app that holds the running code.
  public static var bundledExecutable: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/restic")
  }

  // MARK: - Commands

  /// Creates the repository, opened by `password` or by none, and returns its ID.
  public func createRepository(wallClockLimit: Duration = defaultWallClockLimit) async throws
    -> String
  {
    let completed = try await run(
      ["init"], source: .initialisation, limit: .wallClock(wallClockLimit))
    for case .initialized(let id) in completed.messages { return id }
    throw ResticFailure.unusable("restic didn't say it created the repository")
  }

  /// Saves the contents of `folder` as one snapshot, with the folder as its root: paths inside
  /// it are the same wherever the folder is, so a move or rename changes nothing in the backup,
  /// and a restore writes the contents straight into its target. A backup that couldn't read
  /// some files still saves the rest: it returns, with `isComplete` false and the files in
  /// `unreadable`.
  ///
  /// `patterns` are read as restic reads an exclude file: one per line, trimmed, `$NAME`
  /// expanded and `$$` a literal `$`; a pattern with a `/` matches a whole path, one without a
  /// name anywhere. They go through a file, so there can be any number of them.
  public func backup(
    _ folder: URL, tags: [String] = [], host: String? = nil, excluding patterns: [String] = [],
    excludingCaches: Bool = false, stallLimit: StallLimit = defaultStallLimit,
    onProgress: (@Sendable (BackupProgress) -> Void)? = nil
  ) async throws -> BackupResult {
    let excludeFile = try ExcludeFile(patterns)
    defer { excludeFile.remove() }
    let arguments: [String] =
      ["backup"] + Self.selecting(tags: tags, host: host)
      + (excludeFile.url.map { ["--exclude-file", $0.path] } ?? [])
      + (excludingCaches ? ["--exclude-caches"] : []) + ["--", "."]
    let completed = try await run(
      arguments, source: .backup, limit: stallLimit, accepting: [.incomplete],
      workingDirectory: folder,
      onProgress: { message in
        if case .backupProgress(let progress) = message { onProgress?(progress) }
      })
    for case .backupSummary(let summary) in completed.messages {
      return BackupResult(
        summary: summary, exit: completed.exit,
        unreadable: completed.messages.compactMap { message in
          if case .itemError(let error) = message { error } else { nil }
        })
    }
    throw ResticFailure.unusable("restic printed no summary of the backup")
  }

  public func snapshots(
    tags: [String] = [], host: String? = nil,
    wallClockLimit: Duration = defaultWallClockLimit
  ) async throws -> [ResticSnapshot] {
    let arguments: [String] = ["snapshots"] + Self.selecting(tags: tags, host: host)
    return try await document(
      [ResticSnapshot].self, of: arguments, wallClockLimit: wallClockLimit)
  }

  /// Removes the snapshots (of `tags` and `host`) that `policy` doesn't keep. Their data stays
  /// in the repository until `prune`. A series is the snapshots of one host and set of tags,
  /// wherever they were taken from (restic's own default would start a new series when a folder
  /// moves).
  public func forget(
    keeping policy: ForgetPolicy, tags: [String] = [], host: String? = nil,
    wallClockLimit: Duration = defaultWallClockLimit
  ) async throws -> [ForgetGroup] {
    let arguments: [String] =
      ["forget", "--group-by", "host,tags"] + policy.arguments
      + Self.selecting(tags: tags, host: host)
    // With no snapshot to choose from, restic prints nothing at all, not `[]`.
    return try await document(
      [ForgetGroup].self, of: arguments, wallClockLimit: wallClockLimit, ifSilent: [])
  }

  /// Removes these snapshots, whatever any policy would keep.
  public func forget(
    snapshotIDs: [String], wallClockLimit: Duration = defaultWallClockLimit
  ) async throws {
    guard !snapshotIDs.isEmpty else { return }
    _ = try await run(
      ["forget", "--"] + snapshotIDs, source: .other, limit: .wallClock(wallClockLimit))
  }

  /// Deletes the data no snapshot uses. It leaves a pack whose unused part is small, up to
  /// `maxUnused` of the repository (`"10%"`), and repacks at most `maxRepackSize` (`"1G"`), so a
  /// prune downloads little. It prints nothing a program can follow, so only a wall-clock limit
  /// can tell a hang.
  public func prune(
    maxUnused: String? = nil, maxRepackSize: String? = nil, wallClockLimit: Duration
  ) async throws {
    let arguments =
      ["prune"] + (maxUnused.map { ["--max-unused", $0] } ?? [])
      + (maxRepackSize.map { ["--max-repack-size", $0] } ?? [])
    _ = try await run(arguments, source: .other, limit: .wallClock(wallClockLimit))
  }

  /// What changed from one snapshot to the next, file by file. Paths are as the snapshots hold
  /// them; a folder's end in `/`.
  public func diff(
    from source: String, to target: String, wallClockLimit: Duration = defaultWallClockLimit
  ) async throws -> [DiffChange] {
    let completed = try await run(
      ["diff", source, target], source: .diff, limit: .wallClock(wallClockLimit))
    return completed.messages.compactMap { message in
      if case .diffChange(let change) = message { change } else { nil }
    }
  }

  /// Removes the locks no command holds any more: those of a restic on this Mac that has gone
  /// (killed, or the Mac lost power), and any over 30 minutes old. A lock a killed restic left
  /// stops every command that needs the repository to itself (`prune`, `check`, `forget`) until
  /// then.
  public func unlock(wallClockLimit: Duration = defaultWallClockLimit) async throws {
    _ = try await run(["unlock"], source: .other, limit: .wallClock(wallClockLimit))
  }

  // MARK: Keys

  /// The keys that open the repository; `isCurrent` is the one `password` opened it with.
  public func keys(wallClockLimit: Duration = defaultWallClockLimit) async throws -> [ResticKey] {
    try await document([ResticKey].self, of: ["key", "list"], wallClockLimit: wallClockLimit)
  }

  /// Adds a key that opens the repository with `newPassword`, or with none when it's nil,
  /// beside the one `password` opens, and returns its ID. The new password reaches restic as the
  /// current one does, never through a file on disk, an argument or a variable.
  public func addKey(
    newPassword: String?, wallClockLimit: Duration = defaultWallClockLimit
  ) async throws -> String {
    let completed = try await run(
      ["key", "add"] + (newPassword == nil ? ["--new-insecure-no-password"] : []),
      source: .other, limit: .wallClock(wallClockLimit), newPassword: newPassword)
    let saved = "saved new key with ID "
    for case .other(let line) in completed.messages where line.hasPrefix(saved) {
      return String(line.dropFirst(saved.count)).trimmingCharacters(in: .whitespaces)
    }
    throw ResticFailure.unusable("restic didn't say which key it added")
  }

  /// Removes a key. restic refuses to remove the one `password` opened the repository with.
  public func removeKey(id: String, wallClockLimit: Duration = defaultWallClockLimit)
    async throws
  {
    _ = try await run(["key", "remove", id], source: .other, limit: .wallClock(wallClockLimit))
  }

  /// Checks the repository's structure, and with `readDataSubset` (`"100M"`, `"5%"`, `"1/10"`)
  /// reads that much of its data. A repository with problems returns a summary that isn't
  /// healthy; a check that couldn't run throws.
  public func check(readDataSubset: String? = nil, wallClockLimit: Duration) async throws
    -> CheckSummary
  {
    let arguments = ["check"] + (readDataSubset.map { ["--read-data-subset", $0] } ?? [])
    let completed = try await run(
      arguments, source: .check, limit: .wallClock(wallClockLimit), accepting: [.failed])
    for case .checkSummary(let summary) in completed.messages { return summary }
    throw completed.failure
  }

  /// What the folder at `path` (`/` is the snapshot's root) of `snapshot` holds, one level deep.
  public func tree(
    snapshot: String, path: String = "/", wallClockLimit: Duration = defaultWallClockLimit
  ) async throws -> [TreeNode] {
    struct Tree: Decodable { var nodes: [TreeNode]? }
    let address = path == "/" ? snapshot : "\(snapshot):\(path)"
    return try await document(
      Tree.self, of: ["cat", "tree", address], opening: "{", wallClockLimit: wallClockLimit
    ).nodes ?? []
  }

  /// The bytes a restore of the whole of `snapshot` writes.
  public func restoreSize(
    of snapshot: String, wallClockLimit: Duration = defaultWallClockLimit
  ) async throws -> Int64 {
    struct Stats: Decodable { var totalSize: Int64 }
    return try await document(
      Stats.self, of: ["stats", "--mode", "restore-size", snapshot], opening: "{",
      wallClockLimit: wallClockLimit
    ).totalSize
  }

  /// The size of the file at `path` (from the snapshot's root, `/a/b.txt`) in `snapshot`; nil
  /// when it holds none there. (`stats` measures only whole snapshots.)
  public func size(
    of path: String, in snapshot: String, wallClockLimit: Duration = defaultWallClockLimit
  ) async throws -> Int64? {
    struct Node: Decodable {
      var path: String?
      var type: String?
      var size: Int64?
    }
    let completed = try await run(
      ["ls", snapshot, path], source: .other, limit: .wallClock(wallClockLimit))
    for case .other(let line) in completed.messages where line.hasPrefix("{") {
      guard let node = try? ResticMessage.decodeDocument(Node.self, from: line),
        node.path == path, node.type == "file"
      else { continue }
      return node.size
    }
    return nil
  }

  /// Writes `snapshot` (an ID, `latest`, or either with `:subfolder`) under `target`.
  public func restore(
    snapshot: String, to target: URL, including patterns: [String] = [],
    stallLimit: StallLimit = defaultStallLimit,
    onProgress: (@Sendable (RestoreProgress) -> Void)? = nil
  ) async throws -> RestoreSummary {
    let arguments: [String] =
      ["restore", snapshot, "--target", target.path] + Self.repeated("--include", patterns)
    let completed = try await run(
      arguments, source: .restore, limit: stallLimit,
      onProgress: { message in
        if case .restoreProgress(let progress) = message { onProgress?(progress) }
      })
    for case .restoreSummary(let summary) in completed.messages { return summary }
    throw ResticFailure.unusable("restic printed no summary of the restore")
  }

  // MARK: - Running

  /// `--tag` for each of `tags`, and `--host` when there is one.
  private static func selecting(tags: [String], host: String?) -> [String] {
    var arguments = repeated("--tag", tags)
    if let host { arguments += ["--host", host] }
    return arguments
  }

  /// `option` before each of `values`.
  private static func repeated(_ option: String, _ values: [String]) -> [String] {
    values.flatMap { [option, $0] }
  }

  /// A command that prints its result as one JSON document, a list unless `opening` says, or
  /// `ifSilent` when it prints none.
  private func document<Value: Decodable>(
    _ type: Value.Type, of arguments: [String], opening: String = "[", wallClockLimit: Duration,
    ifSilent: Value? = nil
  ) async throws -> Value {
    let completed = try await run(arguments, source: .other, limit: .wallClock(wallClockLimit))
    for case .other(let line) in completed.messages where line.hasPrefix(opening) {
      do {
        return try ResticMessage.decodeDocument(type, from: line)
      } catch {
        throw ResticFailure.unusable("restic's answer couldn't be read: \(error)")
      }
    }
    guard let ifSilent else { throw ResticFailure.unusable("restic printed no answer") }
    return ifSilent
  }

  /// Runs one command and returns what it printed, or throws unless it exited in success or one
  /// of the exits in `accepting`.
  private func run(
    _ command: [String], source: ResticMessage.Source, limit: StallLimit,
    accepting accepted: [ResticExit] = [], workingDirectory: URL? = nil,
    newPassword: String? = nil, onProgress: (@Sendable (ResticMessage) -> Void)? = nil
  ) async throws -> ResticProcess.Completed {
    let completed = try await ResticProcess(
      executable: executable,
      arguments: globalArguments + command,
      password: password,
      newPassword: newPassword,
      workingDirectory: workingDirectory,
      source: source,
      qualityOfService: qualityOfService,
      limit: limit,
      terminationGrace: terminationGrace,
      onProgress: onProgress
    ).run()
    guard completed.exit == .success || accepted.contains(completed.exit) else {
      throw completed.failure
    }
    return completed
  }

  private var globalArguments: [String] {
    let opening: [String] =
      password == nil ? ["--insecure-no-password"] : ["--password-file", "/dev/stdin"]
    let cache: [String] = cacheDirectory.map { ["--cache-dir", $0.path] } ?? []
    let timeout: [String] =
      stuckRequestTimeout.map { ["--stuck-request-timeout", "\($0.components.seconds)s"] } ?? []
    let connections: [String] =
      restConnections.map { ["--option", "rest.connections=\($0)"] } ?? []
    return ["--json", "--repo", repository] + opening + cache + timeout + connections
  }
}

/// What a `backup` that ran to its end saved.
public struct BackupResult: Equatable, Sendable {
  public var summary: BackupSummary
  var exit: ResticExit
  /// The files that couldn't be read, so aren't in the snapshot.
  public var unreadable: [ItemError]

  /// Whether everything asked for is in the snapshot.
  public var isComplete: Bool { exit == .success }
}

extension ResticProcess.Completed {
  /// The failure a command that exited badly reports: restic's last word, or the exit alone.
  var failure: ResticFailure {
    for case .exitError(_, let message) in messages.reversed() {
      return .exited(exit, message: message)
    }
    return .exited(exit, message: "restic exited with \(exit)")
  }
}

/// The patterns a backup leaves out, in a file for restic to read (`--exclude-file`), so their
/// number is limited by nothing. They name the user's files but hold no secret. None when there
/// are no patterns.
private struct ExcludeFile {
  let url: URL?

  init(_ patterns: [String]) throws {
    guard !patterns.isEmpty else {
      url = nil
      return
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dirbuff-exclude-\(UUID().uuidString)")
    // ponytail: a name with a line break in it would be cut in two here; macOS allows one, and
    // nobody makes one. Un-park if a left-out path is ever seen backed up.
    try patterns.joined(separator: "\n").write(to: url, atomically: false, encoding: .utf8)
    self.url = url
  }

  func remove() {
    if let url { try? FileManager.default.removeItem(at: url) }
  }
}
