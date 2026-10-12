import CryptoKit
import Foundation
import IOKit

/// This Mac, as a licence activation sees it.
public enum Machine {
  /// Shown in Polar's customer portal, so a customer at the activation limit knows which Mac to free.
  public static var name: String { Host.current().localizedName ?? "Mac" }

  /// A hash of the hardware UUID. Polar requires it on every check, so a copied database doesn't
  /// carry the licence to another Mac; the UUID itself never leaves this one.
  public static func id() throws -> String {
    let device = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    defer { IOObjectRelease(device) }
    guard
      let uuid = IORegistryEntryCreateCFProperty(
        device, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
      )?.takeRetainedValue() as? String
    else {
      throw CocoaError(.featureUnsupported)
    }
    return SHA256.hash(data: Data(uuid.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
