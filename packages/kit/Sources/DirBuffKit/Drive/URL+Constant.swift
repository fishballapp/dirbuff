import Foundation

extension URL {
  /// A URL written out in the code, such as a Google endpoint. One that doesn't parse is a typo
  /// caught by the first test that touches it, not a state the app can meet at run time.
  init(constant: StaticString) {
    guard let url = URL(string: "\(constant)") else {
      preconditionFailure("Not a URL: \(constant)")
    }
    self = url
  }
}
