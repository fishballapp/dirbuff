import Foundation
import Testing

@testable import DirBuffKit

/// How the repository password reaches restic: on its standard input, and nowhere else.
@Suite struct ResticPasswordTests {
  @Test func theProcessListShowsNoPasswordAndResticGetsItOnStandardInput() async throws {
    let scratch = try Scratch()
    let record = scratch.url.appendingPathComponent("seen")
    try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
    // What any process of the same user can see while restic runs: its arguments, its
    // environment (`ps -E`), and what it received on stdin, kept as a hash.
    let restic = try stubRestic(
      """
      printf '%s\\n' "$@" > '\(record.path)/arguments'
      ps -wwE -o command= -p $$ > '\(record.path)/ps'
      shasum -a 256 | cut -d' ' -f1 > '\(record.path)/stdin-sha256'
      echo '{"message_type":"initialized","id":"abc","repository":"r"}'
      """, in: scratch)

    _ = try await restic.createRepository()

    let arguments = try String(
      contentsOf: record.appendingPathComponent("arguments"), encoding: .utf8)
    let processList = try String(contentsOf: record.appendingPathComponent("ps"), encoding: .utf8)
    let received = try String(
      contentsOf: record.appendingPathComponent("stdin-sha256"), encoding: .utf8)
    #expect(arguments.contains("--password-file\n/dev/stdin"))
    #expect(!arguments.contains(testPassword))
    #expect(!processList.contains(testPassword))
    #expect(!processList.contains("RESTIC_PASSWORD"))
    #expect(received.trimmingCharacters(in: .whitespacesAndNewlines) == sha256(testPassword))
  }

  @Test func aRepositoryWithNoPasswordIsOpenedWithNone() async throws {
    let scratch = try Scratch()
    let record = scratch.url.appendingPathComponent("arguments")
    var restic = try stubRestic(
      """
      printf '%s\\n' "$@" > '\(record.path)'
      echo '{"message_type":"initialized","id":"abc","repository":"r"}'
      """, in: scratch)
    restic.password = nil

    _ = try await restic.createRepository()

    let arguments = try String(contentsOf: record, encoding: .utf8)
    #expect(arguments.contains("--insecure-no-password\n"))
    #expect(!arguments.contains("--password-file"))
  }

  @Test func aResticVariableInTheEnvironmentIsNotPassedOn() async throws {
    let scratch = try Scratch()
    let record = scratch.url.appendingPathComponent("environment")
    setenv("RESTIC_PASSWORD", "from the app's own environment", 1)
    defer { unsetenv("RESTIC_PASSWORD") }
    let restic = try stubRestic(
      """
      env | grep -E '^(RESTIC|GOMAXPROCS)' | sort > '\(record.path)'
      echo '{"message_type":"initialized","id":"abc","repository":"r"}'
      """, in: scratch)

    _ = try await restic.createRepository()

    #expect(
      try String(contentsOf: record, encoding: .utf8) == "GOMAXPROCS=2\nRESTIC_PROGRESS_FPS=1\n")
  }

  @Test func resticRunsBelowDefaultPriority() async throws {
    let scratch = try Scratch()
    let record = scratch.url.appendingPathComponent("priority")
    let restic = try stubRestic(
      """
      ps -o pri= -p $$ > '\(record.path)'
      echo '{"message_type":"initialized","id":"abc","repository":"r"}'
      """, in: scratch, qualityOfService: Restic.defaultQualityOfService)

    _ = try await restic.createRepository()

    // 31 is the priority of default work.
    let priority = try #require(
      Int(
        try String(contentsOf: record, encoding: .utf8).trimmingCharacters(
          in: .whitespacesAndNewlines)))
    #expect(priority < 31)
  }
}
