/// What the hourly check asks of the Drive account, change or not: a token refresh and
/// `about.get` (5 units). It finds a revoked access or a full Drive on a folder nobody touched.
/// The Google account (ticket 3) conforms; until then nothing is asked.
protocol BackupAccountCheck: Sendable {
  func check() async
}

struct NoBackupAccount: BackupAccountCheck {
  func check() async {}
}
