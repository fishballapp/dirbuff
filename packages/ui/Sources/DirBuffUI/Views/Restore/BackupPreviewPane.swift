import DirBuffKit
import SwiftUI

/// The backup page's sidebar, as Finder's preview pane: the item selected, what became of it on
/// this Mac, Restore and Quick Look, and for a file its timeline across the backups. With nothing
/// in the columns selected, it is the backup itself, which Restore Folder brings back whole.
struct BackupPreviewPane: View {
  var state: BackupBrowserState
  var now: Date
  var calendar: Calendar
  var actions: BackupPageActions

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if let selection = state.selectedPlace {
          item(state.selectedItem, at: selection)
        } else if let backup = state.backup {
          wholeBackup(backup)
        }
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  // MARK: The backup itself

  private func wholeBackup(_ backup: KeptBackup) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      head(
        icon: folderIcon(atPath: state.folderPath), name: state.folderName,
        facts: "As it was \(versionMoment(backup.savedAt, now: now, calendar: calendar))")
      Button("Restore Folder…", action: actions.restoreFolder)
        .buttonStyle(.borderedProminent)
        .tint(Palette.accentBlue)
      note(state.restoreFolderSentence)
      note("Choose a file or folder to restore only that, or drag it to Finder for a copy.")
    }
  }

  // MARK: An item

  @ViewBuilder
  private func item(_ item: BackupItem?, at place: BackupPlace) -> some View {
    let name = place.path.split(separator: "/").last.map(String.init) ?? place.path
    if let item {
      head(icon: BackupItemIcon.image(for: item), name: name, facts: state.facts(of: item))
      if let sinceThen = state.sinceThen(of: item) {
        Label(sinceThen, systemImage: Self.symbol(item.sinceThen))
          .font(.subheadline)
          .foregroundStyle(Palette.inkSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      restore(item, at: place)
      if let drags = state.dragSentence {
        note(drags)
      }
    } else {
      // Its folder isn't listed yet, or couldn't be: the name, and the timeline, which is local.
      head(
        icon: BackupItemIcon.image(for: BackupItem(path: place.path, kind: .file)), name: name,
        facts: nil)
    }
    if let timeline = state.timeline(now: now, calendar: calendar) {
      TimelineList(timeline: timeline, onShow: actions.showEntry)
    }
  }

  @ViewBuilder
  private func restore(_ item: BackupItem, at place: BackupPlace) -> some View {
    switch state.restores[place] {
    case .restoring(let run):
      VStack(alignment: .leading, spacing: 8) {
        Text("Restoring…")
          .font(.headline)
          .foregroundStyle(Palette.ink)
        if run.counts == nil, let busy = state.busyWith {
          note(busy.waitingSentence)
        } else if item.isFolder {
          RestoreProgressBar(run: run)
        } else {
          ProgressView().controlSize(.small)
        }
        Button("Cancel") { actions.cancelRestore(place) }
          .controlSize(.small)
      }
    case .done(let path):
      VStack(alignment: .leading, spacing: 8) {
        note(state.restoredSentence(path: path))
        Button("Show in Finder") { actions.showInFinder([URL(fileURLWithPath: path)]) }
      }
    case .failed(let problem):
      failure(problem, item: item)
    case nil:
      actionsFor(item, at: place)
    }
  }

  private func failure(_ problem: RestoreProblem, item: BackupItem) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(problem.title)
        .font(.headline)
        .foregroundStyle(Palette.ink)
      note(problem.message)
      HStack(spacing: 8) {
        // Enter Password… restores again: that asks for the password and, once it opens the
        // backup, carries on with this restore.
        if let title = problem.fix.title, problem.fix != .tryAgain {
          Button(title) {
            problem.fix == .enterPassword ? actions.restore(item) : actions.fix(problem.fix)
          }
        }
        Button("Try Again") { actions.restore(item) }
      }
    }
  }

  private func actionsFor(_ item: BackupItem, at place: BackupPlace) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Button(state.restoreTitle) { actions.restore(item) }
          .buttonStyle(.borderedProminent)
          .tint(Palette.accentBlue)
        if item.kind == .file {
          Button {
            actions.quickLook(item)
          } label: {
            if state.quickLooking == place {
              ProgressView().controlSize(.small).frame(width: 16)
            } else {
              Label("Quick Look", systemImage: "eye")
            }
          }
          .disabled(!state.canQuickLook(item) || state.quickLooking != nil)
          .help("Preview it (Space)")
        }
      }
      note(state.restoreSentence(for: item))
      if let refusal = state.quickLookRefusal(for: item) {
        note(refusal)
      } else if state.quickLooking == place, let busy = state.busyWith {
        note("Quick Look: \(busy.waitingSentence)")
      }
    }
  }

  // MARK: Parts

  private func head(icon: NSImage, name: String, facts: String?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Image(nsImage: icon)
        .resizable()
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .font(.headline)
          .foregroundStyle(Palette.ink)
          .lineLimit(3)
          .truncationMode(.middle)
        if let facts {
          Text(facts)
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
            .monospacedDigit()
        }
      }
    }
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(Palette.inkTertiary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private static func symbol(_ sinceThen: BackupItem.SinceThen?) -> String {
    switch sinceThen {
    case .deleted: "minus.circle"
    case .unknown: "questionmark.circle"
    case .changed, nil: "pencil.circle"
    }
  }
}

/// A file's versions across the backups, newest first: the one the backup shown holds is
/// selected, and choosing another shows its backup.
private struct TimelineList: View {
  var timeline: FileTimeline
  var onShow: (TimelineEntry) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Palette.rule.frame(height: 1).padding(.vertical, 4)
      Text("In the backups")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Palette.inkTertiary)
        .accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) {
        ForEach(timeline.entries) { entry in
          row(entry)
        }
      }
      if let sentence = timeline.sentence {
        Text(sentence)
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, timeline.entries.isEmpty ? 0 : 2)
      }
    }
  }

  private func row(_ entry: TimelineEntry) -> some View {
    Button {
      onShow(entry)
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Image(
          systemName: entry.version.change == .removed
            ? "minus.circle" : (entry.isCurrent ? "largecircle.fill.circle" : "circle")
        )
        .foregroundStyle(entry.isCurrent ? Palette.accentBlue : Palette.quiet)
        .padding(.top, 1)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
          Text(entry.when)
            .foregroundStyle(entry.canShow ? Palette.ink : Palette.inkTertiary)
          Text(entry.detail)
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
        }
        Spacer(minLength: 0)
      }
      .font(.callout)
      .monospacedDigit()
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(entry.isCurrent ? Palette.blueTint : .clear, in: .rect(cornerRadius: 6))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!entry.canShow)
    .padding(.horizontal, -8)
    .accessibilityAddTraits(entry.isCurrent ? .isSelected : [])
  }
}
