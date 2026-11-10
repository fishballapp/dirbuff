import CryptoKit
import Foundation

@testable import DirBuffKit

/// The restic the app ships, built by `apps/mac/restic/build.sh`.
struct MissingRestic: Error, CustomStringConvertible {
  var description: String {
    "No restic to test with. Build the pinned one with apps/mac/restic/build.sh, or set DIRBUFF_RESTIC."
  }
}

func resticExecutable() throws -> URL {
  if let path = ProcessInfo.processInfo.environment["DIRBUFF_RESTIC"] {
    return URL(fileURLWithPath: path)
  }
  // This file is in projects/dirbuff/packages/kit/Tests/DirBuffKitTests.
  var project = URL(fileURLWithPath: #filePath)
  for _ in 0..<5 { project.deleteLastPathComponent() }
  let built = project.appendingPathComponent("apps/mac/.restic/restic")
  guard FileManager.default.isExecutableFile(atPath: built.path) else { throw MissingRestic() }
  return built
}

let testPassword = "correct horse battery staple"

/// A restic over a folder repository and a cache, both inside `scratch`.
func testRestic(in scratch: Scratch, password: String = testPassword) throws -> Restic {
  Restic(
    executable: try resticExecutable(),
    repository: scratch.url.appendingPathComponent("repository").path,
    password: password,
    cacheDirectory: scratch.url.appendingPathComponent("cache"),
    // Background work crawls on a busy Mac; what runs at that priority is tested on its own.
    qualityOfService: .userInitiated)
}

/// A stand-in for restic that is a shell script, to play out what a real one rarely does.
func stubRestic(
  _ script: String, in scratch: Scratch, terminationGrace: Duration = .seconds(30),
  qualityOfService: QualityOfService = .userInitiated
) throws -> Restic {
  let executable = scratch.url.appendingPathComponent("restic-stub")
  try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  return Restic(
    executable: executable, repository: "unused", password: testPassword,
    terminationGrace: terminationGrace, qualityOfService: qualityOfService)
}

extension Scratch {
  /// Whether any file under here holds `text`.
  func contains(_ text: String) throws -> Bool {
    let needle = Data(text.utf8)
    let files = FileManager.default.enumerator(
      at: url, includingPropertiesForKeys: [.isRegularFileKey])
    return try (files?.allObjects as? [URL] ?? []).contains { file in
      guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        return false
      }
      return try Data(contentsOf: file).range(of: needle) != nil
    }
  }
}

func sha256(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
