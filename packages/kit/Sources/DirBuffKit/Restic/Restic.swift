import Foundation

/// The restic binary in the app bundle, driving one repository.
///
/// Every command runs with `--json`, at utility priority on two cores, with the password on
/// its standard input, and is stopped when it stalls. `repository` is anything restic takes for
/// `-r`: a folder, or the REST address of the Drive bridge.
public struct Restic: Sendable {
  /// `backup` and `restore` are stopped when nothing moves for this long.
  public static let defaultStallLimit = StallLimit.noProgress(for: .seconds(600))

  /// The quick commands (`init`, `snapshots`, `forget`) are stopped after this long.
  public static let defaultWallClockLimit = Duration.seconds(600)

  /// Below what the user is doing (`qualityOfService`).
  public static let defaultQualityOfService = QualityOfService.utility

  public var executable: URL
  public var repository: String
  /// Must not start or end with whitespace: restic trims it.
  public var password: String
  /// Where restic keeps its cache of the repository's index; its own default when nil.
  public var cacheDirectory: URL?
  public var terminationGrace: Duration
  /// Utility: below what the user is doing, on two cores. Background would hand restic the
  /// efficiency cores and little of them while other work runs, and on a busy Mac a backup at
  /// that priority may never finish (opening the repository alone took up to 95 s at a load of 50).
  public var qualityOfService: QualityOfService

  public init(
    executable: URL, repository: String, password: String, cacheDirectory: URL? = nil,
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

  /// Creates the repository and returns its ID.
  public func createRepository(wallClockLimit: Duration = defaultWallClockLimit) async throws
    -> String
  {
    let completed = try await run(
      ["init"], source: .initialisation, limit: .wallClock(wallClockLimit))
    for case .initialized(let id) in completed.messages { return id }
    throw ResticFailure.unusable("restic didn't say it created the repository")
  }

  /// Saves `paths` as one snapshot. A backup that couldn't read some files still saves the rest:
  /// it returns, with `isComplete` false and the files in `unreadable`.
  public func backup(
    _ paths: [URL], tags: [String] = [], host: String? = nil, excluding patterns: [String] = [],
    stallLimit: StallLimit = defaultStallLimit,
    onProgress: (@Sendable (BackupProgress) -> Void)? = nil
  ) async throws -> BackupResult {
    let arguments: [String] =
      ["backup"] + Self.selecting(tags: tags, host: host) + Self.repeated("--exclude", patterns)
      + ["--"] + paths.map(\.path)
    let completed = try await run(
      arguments, source: .backup, limit: stallLimit, accepting: [.incomplete],
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
  /// in the repository until `prune`.
  public func forget(
    keeping policy: ForgetPolicy, tags: [String] = [], host: String? = nil,
    wallClockLimit: Duration = defaultWallClockLimit
  ) async throws -> [ForgetGroup] {
    let arguments: [String] =
      ["forget"] + policy.arguments + Self.selecting(tags: tags, host: host)
    return try await document([ForgetGroup].self, of: arguments, wallClockLimit: wallClockLimit)
  }

  /// Deletes the data no snapshot uses. It prints nothing a program can follow, so only a
  /// wall-clock limit can tell a hang.
  public func prune(wallClockLimit: Duration) async throws {
    _ = try await run(["prune"], source: .other, limit: .wallClock(wallClockLimit))
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

  /// A command that prints its result as one JSON document.
  private func document<Value: Decodable>(
    _ type: Value.Type, of arguments: [String], wallClockLimit: Duration
  ) async throws -> Value {
    let completed = try await run(arguments, source: .other, limit: .wallClock(wallClockLimit))
    for case .other(let line) in completed.messages where line.hasPrefix("[") {
      do {
        return try ResticMessage.decodeDocument(type, from: line)
      } catch {
        throw ResticFailure.unusable("restic's answer couldn't be read: \(error)")
      }
    }
    throw ResticFailure.unusable("restic printed no answer")
  }

  /// Runs one command and returns what it printed, or throws unless it exited in success or one
  /// of the exits in `accepting`.
  private func run(
    _ command: [String], source: ResticMessage.Source, limit: StallLimit,
    accepting accepted: [ResticExit] = [],
    onProgress: (@Sendable (ResticMessage) -> Void)? = nil
  ) async throws -> ResticProcess.Completed {
    let completed = try await ResticProcess(
      executable: executable,
      arguments: globalArguments + command,
      password: password,
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
    ["--json", "--repo", repository, "--password-file", "/dev/stdin"]
      + (cacheDirectory.map { ["--cache-dir", $0.path] } ?? [])
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
