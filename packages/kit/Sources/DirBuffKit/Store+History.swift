import GRDB

extension Store {
  /// History's own migrations, registered after the store's. Each runs once, in order.
  static func registerHistoryMigrations(_ migrator: inout DatabaseMigrator) {}
}
