import Foundation

/// A folder of its own under the temporary directory, removed when the test is done with it.
final class Scratch {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dirbuff-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }

  @discardableResult
  func file(_ path: String, bytes: Int = 1, modified: Date? = nil) throws -> URL {
    let file = url.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(count: bytes).write(to: file)
    if let modified { try setModified(modified, of: file) }
    return file
  }

  @discardableResult
  func folder(_ path: String) throws -> URL {
    let folder = url.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
}

func setModified(_ date: Date, of url: URL) throws {
  try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

func exists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
}

let day: TimeInterval = 86_400

extension Date {
  /// The database keeps dates to the millisecond, so a test compares dates it stored at whole seconds.
  var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
