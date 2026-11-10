/// Unwraps a value that is present by construction: a saved record's id, `trashItem`'s result.
func require<Value>(_ value: Value?) throws -> Value {
  guard let value else { throw MissingValue() }
  return value
}

private struct MissingValue: Error {}
