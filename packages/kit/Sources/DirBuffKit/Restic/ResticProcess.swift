import Foundation
import os

/// One run of the restic binary: starts it, hands it the repository password, reads what it
/// prints and ends it if it stalls.
struct ResticProcess {
  var executable: URL
  var arguments: [String]
  /// Written to restic's standard input, which it reads as a password file. Never a file on
  /// disk, an argument or an environment variable: any process of the same user can read the
  /// last two with `ps`.
  var password: String
  /// A second password, for `key add` (`--new-password-file`). restic gets it through a named
  /// pipe in a folder only this user can open, since `Process` passes a child no descriptors but
  /// its standard ones: the bytes go from this process to restic's, and nothing is written to disk.
  var newPassword: String?
  /// Where restic runs; a backup of `.` makes the folder the snapshot's root.
  var workingDirectory: URL?
  var source: ResticMessage.Source
  var qualityOfService: QualityOfService
  var limit: StallLimit
  /// How long a restic asked to stop has before it is killed.
  var terminationGrace: Duration
  var onProgress: (@Sendable (ResticMessage) -> Void)?

  struct Completed {
    var exit: ResticExit
    /// Everything restic printed except its progress.
    var messages: [ResticMessage]
  }

  func run() async throws -> Completed {
    let newPasswordPipe = try newPassword.map(NamedPipe.init)
    defer { newPasswordPipe?.remove() }
    let process = Process()
    process.executableURL = executable
    process.arguments =
      arguments + (newPasswordPipe.map { ["--new-password-file", $0.url.path] } ?? [])
    process.currentDirectoryURL = workingDirectory
    process.environment = Self.environment
    if let workingDirectory {
      // restic takes the folder's path from `PWD` when it names the same folder, and `PWD` is
      // still the app's: so the path restic records, and matches excludes against, is this one.
      process.environment?["PWD"] = workingDirectory.path
    }
    process.qualityOfService = qualityOfService
    let input = Self.pipe()
    let output = Self.pipe()
    let errors = Self.pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors

    let (terminations, terminated) = AsyncStream.makeStream(of: Termination.self)
    let hasEnded = OSAllocatedUnfairLock(initialState: false)
    process.terminationHandler = {
      hasEnded.withLock { $0 = true }
      terminated.yield(Termination(status: $0.terminationStatus, reason: $0.terminationReason))
      terminated.finish()
    }
    do {
      try process.run()
    } catch {
      throw ResticFailure.unusable("restic didn't start: \(error.localizedDescription)")
    }
    Self.give(password, to: input.fileHandleForWriting)
    newPasswordPipe?.write(until: { hasEnded.withLock { $0 } })

    let supervision = Supervision(
      processID: process.processIdentifier, limit: limit, terminationGrace: terminationGrace)
    let printed = Printed()

    let termination = await withTaskCancellationHandler {
      async let outputRead: Void = read(output.fileHandleForReading, into: printed, supervision)
      async let errorsRead: Void = read(errors.fileHandleForReading, into: printed, supervision)
      var iterator = terminations.makeAsyncIterator()
      let termination = await iterator.next()
      supervision.processEnded()
      await outputRead
      await errorsRead
      return termination
    } onCancel: {
      supervision.stop()
    }

    if let stalledBy = supervision.stalledBy { throw ResticFailure.stalled(stalledBy) }
    try Task.checkCancellation()
    guard let termination else { throw ResticFailure.unusable("restic's exit wasn't reported") }
    return Completed(exit: termination.exit, messages: printed.messages)
  }

  private func read(_ handle: FileHandle, into printed: Printed, _ supervision: Supervision) async {
    for await line in Self.lines(of: handle) {
      let message = ResticMessage(line: line, from: source)
      guard let mark = message.progressMark else {
        printed.add(message)
        continue
      }
      supervision.sawProgress(mark)
      onProgress?(message)
    }
  }

  /// The lines a pipe carries, each as soon as it is whole, until restic closes it.
  /// (`FileHandle.bytes` holds back what it has read until its buffer is full.)
  private static func lines(of handle: FileHandle) -> AsyncStream<String> {
    AsyncStream { continuation in
      let splitter = LineSplitter()
      handle.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else {
          handle.readabilityHandler = nil
          if let rest = splitter.rest { continuation.yield(rest) }
          continuation.finish()
          return
        }
        for line in splitter.append(data) { continuation.yield(line) }
      }
    }
  }

  /// restic's own environment variables could make it read a password or a repository from
  /// somewhere else, so none is passed on.
  private static var environment: [String: String] {
    var environment = ProcessInfo.processInfo.environment.filter { name, _ in
      !name.hasPrefix("RESTIC_") && name != "GOMAXPROCS"
    }
    // Two of the cores: a backup runs for hours, and the Mac stays usable.
    environment["GOMAXPROCS"] = "2"
    // One status a second, instead of ten.
    environment["RESTIC_PROGRESS_FPS"] = "1"
    return environment
  }

  /// A pipe no other process inherits. The one that restic reads its password from ends only when
  /// every copy of its write end is closed, so a restic or any other child started at the same
  /// moment, holding a copy, would keep it waiting for ever. The ends restic is given are
  /// duplicated onto its standard streams, which clears this.
  private static func pipe() -> Pipe {
    let pipe = Pipe()
    for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting] {
      _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
    }
    return pipe
  }

  private static func give(_ password: String, to handle: FileHandle) {
    // A restic that has already died must cost this write an error, not the app a SIGPIPE.
    _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    try? handle.write(contentsOf: Data(password.utf8))
    try? handle.close()
  }
}

private struct Termination: Sendable {
  var status: Int32
  var reason: Process.TerminationReason

  var exit: ResticExit {
    // A signal ends the process with no exit code: report it as the negative signal number.
    reason == .uncaughtSignal ? .other(-status) : ResticExit(code: status)
  }
}

/// What a restic run printed, besides its progress.
private final class Printed: @unchecked Sendable {
  private let lock = NSLock()
  private var all: [ResticMessage] = []

  var messages: [ResticMessage] { lock.withLock { all } }

  func add(_ message: ResticMessage) {
    lock.withLock { all.append(message) }
  }
}

/// Watches a running restic and stops it when it stalls or its caller gives up.
private final class Supervision: @unchecked Sendable {
  private let processID: Int32
  private let limit: StallLimit
  private let terminationGrace: Duration
  private let lock = NSLock()
  private let startedAt = ContinuousClock.now
  private var lastMark: ResticMessage.ProgressMark?
  private var lastProgressAt = ContinuousClock.now
  private var hasEnded = false
  private var timer: DispatchSourceTimer?
  private var killer: DispatchWorkItem?
  private var stalled: StallLimit?

  init(processID: Int32, limit: StallLimit, terminationGrace: Duration) {
    self.processID = processID
    self.limit = limit
    self.terminationGrace = terminationGrace
    startTimer()
  }

  /// The limit that stopped restic, if one did.
  var stalledBy: StallLimit? { lock.withLock { stalled } }

  func sawProgress(_ mark: ResticMessage.ProgressMark) {
    lock.withLock {
      guard mark != lastMark else { return }
      lastMark = mark
      lastProgressAt = .now
    }
  }

  func processEnded() {
    lock.withLock {
      hasEnded = true
      timer?.cancel()
      killer?.cancel()
    }
  }

  /// Asks restic to stop, which it does cleanly (releasing the repository's lock), and kills it
  /// if it hasn't within the grace period.
  func stop() {
    lock.withLock {
      guard !hasEnded, killer == nil else { return }
      kill(processID, SIGTERM)
      let killer = DispatchWorkItem { [self] in
        lock.withLock {
          if !hasEnded { kill(processID, SIGKILL) }
        }
      }
      self.killer = killer
      DispatchQueue.global().asyncAfter(
        deadline: .now() + terminationGrace.timeInterval, execute: killer)
    }
  }

  private func startTimer() {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    let period = max(.milliseconds(10), min(.seconds(5), limit.duration / 20))
    timer.schedule(deadline: .now() + period.timeInterval, repeating: period.timeInterval)
    timer.setEventHandler { [self] in
      guard isOverdue else { return }
      stop()
    }
    self.timer = timer
    timer.resume()
  }

  private var isOverdue: Bool {
    lock.withLock {
      guard !hasEnded, stalled == nil else { return false }
      let since =
        switch limit {
        case .noProgress: lastProgressAt
        case .wallClock: startedAt
        }
      let isOverdue = ContinuousClock.now - since >= limit.duration
      if isOverdue { stalled = limit }
      return isOverdue
    }
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
  }
}

/// Cuts what a pipe delivers, in pieces of any size, into lines. Used from one handler at a time.
private final class LineSplitter: @unchecked Sendable {
  private var pending = Data()

  /// What came after the last newline, when the pipe has closed.
  var rest: String? {
    pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
  }

  func append(_ data: Data) -> [String] {
    pending.append(data)
    var lines: [String] = []
    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
      lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
      pending = Data(pending[pending.index(after: newline)...])
    }
    return lines
  }
}

/// A named pipe that carries one secret to the restic reading it. Its folder is new and open to
/// this user only, and is removed once restic is done.
private final class NamedPipe: Sendable {
  let url: URL
  private let secret: String

  init(_ secret: String) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dirbuff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    url = folder.appendingPathComponent("secret")
    self.secret = secret
    guard mkfifo(url.path, 0o600) == 0 else {
      try? FileManager.default.removeItem(at: folder)
      throw ResticFailure.unusable("Couldn't make a pipe for the new password (errno \(errno))")
    }
  }

  /// Writes the secret once restic opens the pipe, from another thread: opening a pipe to write
  /// waits for its reader, and gives up when `hasEnded` says restic stopped without opening it.
  func write(until hasEnded: @escaping @Sendable () -> Bool) {
    Thread.detachNewThread { [self] in
      while true {
        let descriptor = open(url.path, O_WRONLY | O_NONBLOCK)
        if descriptor >= 0 {
          _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
          _ = Data(secret.utf8).withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, $0.count)
          }
          close(descriptor)
          return
        }
        // No reader yet (`ENXIO`) is the one failure worth waiting out.
        guard errno == ENXIO, !hasEnded() else { return }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }
}
