import Foundation

/// What the triggers keep across launches: each folder's place in its volume's event journal,
/// and the day `maintain` last succeeded. A folder with no place starts as changed.
struct BackupTriggerMemory {
  private let defaults: UserDefaults
  private static let placesKey = "backupTriggerPlaces"
  private static let maintainedKey = "backupMaintainedAt"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The event ID each folder was last backed up at. A folder taken off Backup leaves its place
  /// behind: a few bytes, and a Backup put on again starts with a backup anyway.
  var places: [Int64: FolderChangeStream.Place] {
    get {
      defaults.data(forKey: Self.placesKey)
        .flatMap { try? JSONDecoder().decode([Int64: FolderChangeStream.Place].self, from: $0) }
        ?? [:]
    }
    nonmutating set {
      defaults.set(try? JSONEncoder().encode(newValue), forKey: Self.placesKey)
    }
  }

  var maintainedAt: Date? {
    get { defaults.object(forKey: Self.maintainedKey) as? Date }
    nonmutating set { defaults.set(newValue, forKey: Self.maintainedKey) }
  }
}
