import DirBuffCore
import SwiftUI

/// Backup's one setting as a sentence: "Every file goes to your Google Drive, keeping every
/// version, thinning with age.", with a line under it on what that means. The history's pop-up
/// comes with the buff going live.
struct BackupSettingView: View {
  var settings: BackupSettings
  var meaning: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(
        "Every file goes to your Google Drive, keeping \(lowercasingFirst(backupSetting(settings)))."
      )
      .foregroundStyle(Palette.ink)
      .fixedSize(horizontal: false, vertical: true)
      Text(meaning)
        .font(.subheadline)
        .foregroundStyle(Palette.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
