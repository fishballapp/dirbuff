import Foundation

/// Where each of a restic repository's files sits: restic's own local layout, so a downloaded
/// copy of the Drive folder opens with `restic -r <folder>`. The REST protocol names files flat
/// (`data/<name>`); on Drive, `data/` is sharded into `00` … `ff` by the name's first two
/// characters, as restic does on disk.
enum RepositoryLayout {
  /// The kinds of file a repository holds besides `config`, each in its own folder.
  enum FileType: String, CaseIterable, Sendable {
    case data, keys, locks, snapshots, index
  }

  static let config = "config"

  /// Every folder of a new repository, parents first.
  static let folders: [String] =
    FileType.allCases.map(\.rawValue) + (0...255).map { "data/" + String(format: "%02x", $0) }

  /// The file's path in the repository.
  static func path(of type: FileType, named name: String) -> String {
    type == .data ? "data/\(name.prefix(2))/\(name)" : "\(type.rawValue)/\(name)"
  }

  /// restic names every file but `config` by the SHA-256 of its contents, in lowercase hex.
  static func isFileName(_ name: some StringProtocol) -> Bool {
    name.count == 64 && name.allSatisfy { "0123456789abcdef".contains($0) }
  }
}
