import DirBuffKit
import SwiftUI

/// Restore from Google Drive…: the Macs' backups, a backup's folders and dates, a place to put
/// the folder, and **Keep Backing Up Here**, whose effect is said before it happens.
public struct RestoreFromDriveSheet: View {
  public var state: RestoreFromDriveState
  public var now: Date
  public var calendar: Calendar
  /// The Mac's home, so a folder's path reads "~/Documents".
  public var home: String
  /// A Mac chosen in the list, by its ID.
  public var onSelectMac: (String) -> Void
  public var onOpenMac: (BackedUpMac) -> Void
  public var onSubmitPassword: (String) -> Void
  public var onSelectFolder: (String) -> Void
  public var onSelectDate: (String) -> Void
  public var onChoosePlace: () -> Void
  public var onRestore: () -> Void
  public var onRestoreAnother: () -> Void
  /// Back, from choosing another folder to the ones already restored.
  public var onBack: () -> Void
  public var onKeep: () -> Void
  public var onShowInFinder: (RestoredFolder) -> Void
  public var onFix: (RestoreProblem.Fix) -> Void
  /// Cancel, Not Now and Done: closes the sheet, stopping a restore under way.
  public var onClose: () -> Void

  @State private var password: String

  public init(
    state: RestoreFromDriveState,
    now: Date = Date(),
    calendar: Calendar = .current,
    home: String = NSHomeDirectory(),
    password: String = "",
    onSelectMac: @escaping (String) -> Void = { _ in },
    onOpenMac: @escaping (BackedUpMac) -> Void = { _ in },
    onSubmitPassword: @escaping (String) -> Void = { _ in },
    onSelectFolder: @escaping (String) -> Void = { _ in },
    onSelectDate: @escaping (String) -> Void = { _ in },
    onChoosePlace: @escaping () -> Void = {},
    onRestore: @escaping () -> Void = {},
    onRestoreAnother: @escaping () -> Void = {},
    onBack: @escaping () -> Void = {},
    onKeep: @escaping () -> Void = {},
    onShowInFinder: @escaping (RestoredFolder) -> Void = { _ in },
    onFix: @escaping (RestoreProblem.Fix) -> Void = { _ in },
    onClose: @escaping () -> Void = {}
  ) {
    self.state = state
    self.now = now
    self.calendar = calendar
    self.home = home
    self.onSelectMac = onSelectMac
    self.onOpenMac = onOpenMac
    self.onSubmitPassword = onSubmitPassword
    self.onSelectFolder = onSelectFolder
    self.onSelectDate = onSelectDate
    self.onChoosePlace = onChoosePlace
    self.onRestore = onRestore
    self.onRestoreAnother = onRestoreAnother
    self.onBack = onBack
    self.onKeep = onKeep
    self.onShowInFinder = onShowInFinder
    self.onFix = onFix
    self.onClose = onClose
    self._password = State(initialValue: password)
  }

  public var body: some View {
    switch state.step {
    case .loadingMacs:
      RestoreSheetShell(
        sentences: [
          "DirBuff looks in \(state.account ?? "your Google Drive") for the backups your Macs made."
        ]
      ) {
        Text(state.title)
      } content: {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Asking Google Drive…")
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
        }
      } buttons: {
        Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
      }

    case .macs(let macs):
      if macs.isEmpty {
        RestoreSheetShell(
          sentences: [
            "\(state.account ?? "Your Google Drive") has no DirBuff Backup folder with a backup in it. If the backup is in another Google account, sign out in Settings and sign in with that one."
          ]
        ) {
          Text("No backups found")
        } buttons: {
          Button("Close", action: onClose).keyboardShortcut(.defaultAction)
        }
      } else {
        RestoreSheetShell(
          sentences: ["Choose the Mac whose backup you want to restore from."]
        ) {
          Text(state.title)
        } content: {
          MacList(macs: macs, selected: state.selectedMacID, onSelect: onSelectMac)
        } buttons: {
          Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
          Button("Open Backup") {
            if let mac = macs.first(where: { $0.id == state.selectedMacID }) { onOpenMac(mac) }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(state.selectedMacID == nil)
        }
      }

    case .password(let ask):
      RestoreSheetShell(sentences: [ask.explanation]) {
        Text(state.title)
      } content: {
        RestorePasswordForm(ask: ask, password: $password) { onSubmitPassword(password) }
      } buttons: {
        Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
        Button("Open Backup") { onSubmitPassword(password) }
          .keyboardShortcut(.defaultAction)
          .disabled(password.isEmpty || ask.isChecking)
      }

    case .loadingFolders:
      RestoreSheetShell {
        Text(state.title)
      } content: {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Reading the backup's folders and dates…")
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
        }
      } buttons: {
        Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
      }

    case .folders(let pick):
      RestoreSheetShell(
        width: 540,
        sentences: [
          "Choose a folder and the date to bring it back as. It comes back as a new folder in the place you choose, and nothing there is replaced."
        ]
      ) {
        Text(state.title)
      } content: {
        FolderChoice(
          pick: pick, now: now, calendar: calendar, home: home, onSelectFolder: onSelectFolder,
          onSelectDate: onSelectDate, onChoosePlace: onChoosePlace)
      } buttons: {
        if !state.restored.isEmpty {
          Button("Back", action: onBack).help("Back to the folders already restored")
        }
        Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
        Button("Restore Folder", action: onRestore)
          .keyboardShortcut(.defaultAction)
          .disabled(pick.snapshot == nil)
      }

    case .restoring(let run):
      RestoreSheetShell(
        sentences: [
          "It is written to a temporary place first and moved into the folder you chose when it is whole, so a cancelled restore leaves nothing behind."
        ]
      ) {
        HStack(spacing: 5) {
          Text("Restoring")
          FolderPill(run.folderName, path: run.path)
        }
      } content: {
        RestoreProgressBar(run: run)
      } buttons: {
        Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
      }

    case .restored:
      RestoreSheetShell(width: 540, sentences: [state.restoredDetail]) {
        Text(state.title)
      } content: {
        RestoredList(
          folders: state.restored, plainCopies: Set(state.plainCopies.map(\.path)),
          keepExplanation: state.keepExplanation, onShowInFinder: onShowInFinder)
      } buttons: {
        Button("Restore Another Folder", action: onRestoreAnother)
        Spacer()
        Button("Not Now", action: onClose).keyboardShortcut(.cancelAction)
        Button("Keep Backing Up Here", action: onKeep).keyboardShortcut(.defaultAction)
      }

    case .keeping:
      RestoreSheetShell {
        Text(state.title)
      } content: {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Checking the backup, then switching this Mac to it…")
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
        }
      } buttons: {
        EmptyView()
      }

    case .kept:
      RestoreSheetShell(sentences: [state.keptDetail]) {
        Text(state.title)
      } buttons: {
        Button("Done", action: onClose).keyboardShortcut(.defaultAction)
      }

    case .failed(let problem):
      RestoreSheetShell(sentences: [problem.message]) {
        Text(problem.title)
      } buttons: {
        Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        if let title = problem.fix.title {
          Button(title) { onFix(problem.fix) }.keyboardShortcut(.defaultAction)
        }
      }
    }
  }
}

/// The Macs that have a backup, this one marked.
private struct MacList: View {
  var macs: [BackedUpMac]
  var selected: String?
  var onSelect: (String) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ForEach(macs, id: \.id) { mac in
        Button {
          onSelect(mac.id)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "laptopcomputer")
              .foregroundStyle(Palette.inkTertiary)
              .frame(width: 20)
              .accessibilityHidden(true)
            Text(mac.name)
              .foregroundStyle(Palette.ink)
              .lineLimit(1)
            if mac.isThisMac {
              Text("This Mac")
                .font(.subheadline)
                .foregroundStyle(Palette.inkTertiary)
                .padding(.horizontal, 7)
                .background(Color.primary.opacity(0.07), in: .capsule)
            }
            Spacer(minLength: 8)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 7)
          .background(selected == mac.id ? Palette.blueTint : .clear)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected == mac.id ? .isSelected : [])
      }
    }
    .background(Palette.card)
    .clipShape(.rect(cornerRadius: 8))
    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.ruleStrong, lineWidth: 1) }
  }
}

/// A backup's folders, the dates of the one chosen, and where it goes.
private struct FolderChoice: View {
  var pick: FolderPick
  var now: Date
  var calendar: Calendar
  var home: String
  var onSelectFolder: (String) -> Void
  var onSelectDate: (String) -> Void
  var onChoosePlace: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(spacing: 0) {
        ForEach(pick.folders, id: \.series) { folder in
          Button {
            onSelectFolder(folder.series)
          } label: {
            HStack(spacing: 10) {
              Image(nsImage: folderIcon(atPath: folder.path))
                .resizable()
                .frame(width: 20, height: 18)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                  .foregroundStyle(Palette.ink)
                  .lineLimit(1)
                Text(FolderPick.detail(folder, home: home))
                  .font(.subheadline)
                  .foregroundStyle(Palette.inkTertiary)
                  .lineLimit(1)
                  .truncationMode(.middle)
              }
              Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(pick.selectedSeries == folder.series ? Palette.blueTint : .clear)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(pick.selectedSeries == folder.series ? .isSelected : [])
        }
      }
      .background(Palette.card)
      .clipShape(.rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.ruleStrong, lineWidth: 1)
      }

      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        GridRow {
          Text("As it was").gridColumnAlignment(.trailing)
          Picker(
            "As it was",
            selection: Binding(
              get: { pick.selectedSnapshotID ?? "" }, set: { onSelectDate($0) })
          ) {
            ForEach(pick.dates(now: now, calendar: calendar)) { date in
              Text("\(date.when) · \(date.detail)").tag(date.id)
            }
          }
          .labelsHidden()
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        GridRow {
          Text("Put it in")
          HStack(spacing: 8) {
            Image(nsImage: folderIcon(atPath: pick.destination))
              .resizable()
              .frame(width: 18, height: 16)
              .accessibilityHidden(true)
            Text(pick.destinationName)
              .foregroundStyle(Palette.ink)
              .lineLimit(1)
              .truncationMode(.middle)
            Button("Choose…", action: onChoosePlace)
              .controlSize(.small)
          }
        }
      }
    }
  }
}

/// The folders brought back so far, each with a Finder button.
private struct RestoredList: View {
  var folders: [RestoredFolder]
  /// Older restores of a series a newer one carries on: they stay plain copies.
  var plainCopies: Set<String>
  var keepExplanation: [String]
  var onShowInFinder: (RestoredFolder) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(folders) { folder in
          HStack(spacing: 8) {
            FolderPill(folder.name, path: folder.path)
            if plainCopies.contains(folder.path) {
              Text("Stays a plain copy")
                .font(.subheadline)
                .foregroundStyle(Palette.inkTertiary)
            }
            Spacer(minLength: 8)
            GhostIconButton("Show in Finder", systemImage: GhostIconButton.finderSymbol) {
              onShowInFinder(folder)
            }
          }
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("What Keep Backing Up Here does")
          .fontWeight(.semibold)
          .foregroundStyle(Palette.ink)
        ForEach(keepExplanation, id: \.self) { line in
          Text(line)
            .foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
