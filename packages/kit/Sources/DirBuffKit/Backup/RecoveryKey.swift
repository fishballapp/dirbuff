/// A key for the repository that a person can copy out and type back: 30 characters of
/// Crockford's base32 (no I, L, O or U to misread), in six groups of five, 150 bits in all.
enum RecoveryKey {
  private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  /// From the system's cryptographically secure generator.
  static func make() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<6).map { _ in
      String((0..<5).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }.joined(separator: "-")
  }
}
