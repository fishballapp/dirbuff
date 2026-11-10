import Foundation

/// Why a Google call failed, in the terms Backup acts on. Each case is a cause the failure table
/// turns into a state; anything Backup can't act on is `rejected`.
public enum DriveProblem: Error, Equatable, Sendable {
  /// Google no longer honours the refresh token (access revoked, 6 months unused, a session
  /// policy), or there is none. The user has to sign in again.
  case signedOut
  /// `storageQuotaExceeded`: the account has no room left.
  case storageFull
  /// Google's daily upload limit for the account.
  case dailyUploadLimit
  /// A 404: the file or folder is gone (or was never ours to see).
  case notFound
  /// Rate limits (403 or 429) kept answering after every retry.
  case rateLimited
  /// No answer: offline, a dropped connection, or Google failing on every retry.
  case unreachable
  /// The stored file's checksum isn't the one sent, so it isn't safe to call stored.
  case checksumMismatch(sent: String, stored: String?)
  /// Anything else Google refused, with its own words.
  case rejected(status: Int, reason: String?, message: String)
}

extension DriveProblem {
  /// The `error` object of a Drive API reply.
  struct Body: Decodable {
    struct Detail: Decodable {
      struct Entry: Decodable { var reason: String? }
      var message: String?
      var errors: [Entry]?
    }
    var error: Detail?

    var reason: String? { error?.errors?.first?.reason }
    var message: String { error?.message ?? "" }
  }

  /// How a reply that isn't a success is told apart: `nil` means "wait and ask again".
  /// A 401 never reaches here; the transport refreshes the token first.
  static func classify(status: Int, data: Data) -> DriveProblem? {
    let body = try? JSONDecoder().decode(Body.self, from: data)
    let reason = body?.reason
    switch (status, reason) {
    case (404, _): return .notFound
    case (_, "storageQuotaExceeded"): return .storageFull
    case (_, "dailyLimitExceeded"): return .dailyUploadLimit
    case (429, _), (403, "rateLimitExceeded"), (403, "userRateLimitExceeded"),
      (403, "sharingRateLimitExceeded"), (500..<600, _):
      return nil
    default:
      return .rejected(status: status, reason: reason, message: body?.message ?? "")
    }
  }
}
