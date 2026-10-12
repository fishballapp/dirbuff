import Foundation

/// What the user's macOS calls the Bin: "Bin" in British English, "Trash" in American English.
///
/// The name comes in the app's language, so the app declares `en-GB` (its Info.plist's
/// `CFBundleLocalizations`); with only `en`, a British Mac reads "Trash".
public enum SystemBin {
  public static var name: String {
    name(for: FileManager.default)
  }

  public static func name(for fileManager: FileManager) -> String {
    guard
      let url = try? fileManager.url(
        for: .trashDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
      ),
      let localized = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName,
      !localized.isEmpty
    else {
      return "Bin"
    }
    return localized
  }
}
