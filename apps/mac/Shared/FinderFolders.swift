import DirBuffUI
import Foundation

/// The folders as the app last saw them, for the Finder extension's badge and right-click item. The
/// extension's sandbox can't read a folder's tags or find the real home folder, so the app
/// publishes the snapshot to the app group they share.
enum FinderFolders {
  static var defaults: UserDefaults? { UserDefaults(suiteName: "9CWXH66CKT.app.fishball.dirbuff") }
}

extension UserDefaults {
  /// Encoded `FinderSnapshot`. Observable with key-value observing, including changes another
  /// process makes, because the property is named after its key.
  @objc dynamic var finderSnapshot: Data? {
    get { data(forKey: #function) }
    set { set(newValue, forKey: #function) }
  }

  /// The folders at the top of every volume but the startup disk, which the extension watches in
  /// place of the volume.
  @objc dynamic var volumeTopFolderPaths: [String] {
    get { stringArray(forKey: #function) ?? [] }
    set { set(newValue, forKey: #function) }
  }

  /// Reads the decoded `FinderSnapshot`, or an empty snapshot when none has been published yet.
  /// Writes only when the sorted-key JSON bytes differ from what is already stored.
  var snapshot: FinderSnapshot {
    get { FinderSnapshot.decode(finderSnapshot) }
    set {
      guard let encoded = newValue.encoded(), finderSnapshot != encoded else { return }
      finderSnapshot = encoded
    }
  }
}
