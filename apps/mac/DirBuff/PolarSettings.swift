import Foundation

/// Which Polar this build talks to: build settings carried into `Info.plist`.
struct PolarSettings {
  let api: URL
  let organizationID: String
  let checkout: URL
  let portal: URL

  /// A missing value is a broken build, so it stops the app rather than guessing a Polar.
  static func fromInfoPlist() throws -> PolarSettings {
    func value(_ key: String) throws -> String {
      guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty
      else { throw CocoaError(.propertyListReadCorrupt, userInfo: ["key": key]) }
      return value
    }
    func url(_ key: String) throws -> URL {
      guard let url = URL(string: try value(key)) else {
        throw CocoaError(.propertyListReadCorrupt, userInfo: ["key": key])
      }
      return url
    }
    return PolarSettings(
      api: try url("DirBuffPolarAPI"),
      organizationID: try value("DirBuffPolarOrganizationID"),
      checkout: try url("DirBuffPolarCheckoutURL"),
      portal: try url("DirBuffPolarPortalURL"))
  }
}
