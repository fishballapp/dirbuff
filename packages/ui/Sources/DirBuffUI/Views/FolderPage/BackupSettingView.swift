import DirBuffCore
import SwiftUI

/// Backup's one setting as a sentence with a pop-up in it: "Every file goes to
/// mei.chan@gmail.com's Google Drive, keeping [every version, thinning with age].", with a line
/// under it on what that means. A longer history takes effect at once; a shorter one asks first,
/// since the versions it drops are deleted from Drive at the next upkeep.
struct BackupSettingView: View {
  var settings: BackupSettings
  var meaning: String
  var account: String?
  var folderName: String
  var onChange: (BackupSettings) -> Void

  /// A shorter history waiting for the user to confirm.
  @State private var shorterToConfirm: BackupSettings?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      SentenceFlow {
        words("Every file goes to")
        if let account {
          Text("\(account)’s")
        } else {
          words("your")
        }
        words("Google Drive, keeping")
        SettingPopUp(entries: entries, selection: settings.history, onChoose: choose)
          .accessibilityLabel("Keeping")
        Text(".").hugsPrevious()
      }
      .foregroundStyle(Palette.ink)

      Text(meaning)
        .font(.subheadline)
        .foregroundStyle(Palette.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .alert(
      shorterToConfirm.map {
        ShorterHistoryWords(history: $0.history, folderName: folderName).title
      }
        ?? "",
      isPresented: Binding(
        get: { shorterToConfirm != nil }, set: { if !$0 { shorterToConfirm = nil } }),
      presenting: shorterToConfirm
    ) { next in
      Button(ShorterHistoryWords(history: next.history, folderName: folderName).button) {
        onChange(next)
      }
      Button("Cancel", role: .cancel) {}
    } message: { next in
      Text(ShorterHistoryWords(history: next.history, folderName: folderName).message)
    }
  }

  /// One `Text` per word, so the sentence can wrap between them.
  private func words(_ text: String) -> some View {
    ForEach(Array(text.split(separator: " ").enumerated()), id: \.offset) { _, word in
      Text(word)
    }
  }

  private var entries: [SettingPopUp<BackupHistory>.Entry] {
    [
      .choice(.forever, title: "every version, thinning with age"),
      .separator,
      .choice(
        .oneYear, title: "versions for one year", subtitle: "Older ones are deleted from Drive"),
      .choice(
        .thirtyDays, title: "versions for 30 days", subtitle: "Older ones are deleted from Drive"),
    ]
  }

  private func choose(_ history: BackupHistory) {
    let next = BackupSettings(history: history)
    guard next != settings else { return }
    if history.keepsLess(than: settings.history) {
      shorterToConfirm = next
    } else {
      onChange(next)
    }
  }
}

/// The question before a shorter history, from the pop-up or from Undo: what it drops is
/// deleted from Drive at the next upkeep.
struct ShorterHistoryWords {
  var history: BackupHistory
  var folderName: String

  var title: String {
    switch history {
    case .forever: "Keep every version of \(folderName)?"
    case .oneYear: "Keep only a year of versions of \(folderName)?"
    case .thirtyDays: "Keep only 30 days of versions of \(folderName)?"
    }
  }

  var button: String {
    switch history {
    case .forever: "Keep Every Version"
    case .oneYear: "Keep One Year"
    case .thirtyDays: "Keep 30 Days"
    }
  }

  var message: String {
    "Older versions of \(folderName) are deleted from your Google Drive at the next daily upkeep, and can't be brought back."
  }
}

extension BackupHistory {
  /// Whether it keeps fewer old versions than `other`: changing to it deletes some.
  func keepsLess(than other: BackupHistory) -> Bool {
    func reach(_ history: BackupHistory) -> Int {
      switch history {
      case .forever: 2
      case .oneYear: 1
      case .thirtyDays: 0
      }
    }
    return reach(self) < reach(other)
  }
}
