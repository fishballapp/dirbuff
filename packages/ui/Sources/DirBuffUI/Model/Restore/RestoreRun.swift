import DirBuffKit
import Foundation

/// A restore under way, as the sheet that started it and the menu-bar popover both show it: the
/// folder being brought back and how far the download has got.
public struct RestoreRun: Sendable, Equatable {
  /// The folder being restored: "Documents".
  public var folderName: String
  /// Where it is going, for the folder pill's icon.
  public var path: String
  /// How much of the download is done, from 0 to 1.
  public var fraction: Double
  /// "1.2 of 3.4 GB · 120 of 340 files"; nil until restic has reported how much there is.
  public var counts: String?

  public init(folderName: String, path: String, progress: RestoreProgress? = nil) {
    self.folderName = folderName
    self.path = path
    guard let progress else {
      fraction = 0
      counts = nil
      return
    }
    fraction =
      progress.totalBytes > 0
      ? min(1, Double(progress.bytesRestored) / Double(progress.totalBytes))
      : min(1, max(0, progress.percentDone))
    var parts: [String] = []
    if progress.totalBytes > 0 {
      parts.append(amountOf(Int64(progress.bytesRestored), Int64(progress.totalBytes)))
    }
    if progress.totalFiles > 0 {
      parts.append(
        "\(progress.filesRestored.formatted()) of \(progress.totalFiles.formatted()) files")
    }
    counts = parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}
