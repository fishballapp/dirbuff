import AppKit
import DirBuffCore
import DirBuffKit
import SwiftUI

/// A folder in the main window: its Temporary switch and, while it's on, what goes and the rules.
public struct FolderDetailView: View {
  public var folder: MainFolder
  public var binName: String
  /// Set while the folders are plain because the trial or licence ended.
  public var licenceRefusal: String?
  public var buyTitle: String
  public var onSetTemporary: (Bool) -> Void
  public var onChangeSettings: (TemporarySettings) -> Void
  public var onBuy: () -> Void

  /// Settings that would start deleting permanently, waiting for the user to confirm.
  @State private var deleteToConfirm: TemporarySettings?

  private var settings: TemporarySettings { folder.settings }

  public init(
    folder: MainFolder,
    binName: String = SystemBin.name,
    licenceRefusal: String? = nil,
    buyTitle: String = LicenceLine.Action.buy.title,
    onSetTemporary: @escaping (Bool) -> Void = { _ in },
    onChangeSettings: @escaping (TemporarySettings) -> Void = { _ in },
    onBuy: @escaping () -> Void = {}
  ) {
    self.folder = folder
    self.binName = binName
    self.licenceRefusal = licenceRefusal
    self.buyTitle = buyTitle
    self.onSetTemporary = onSetTemporary
    self.onChangeSettings = onChangeSettings
    self.onBuy = onBuy
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Form {
        Section {
          Toggle(
            isOn: Binding(
              get: { folder.isTemporary },
              set: { onSetTemporary($0) }
            )
          ) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Temporary")
              Text("Clears old things out of this folder on the hour, by the rules below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .toggleStyle(.switch)
          .disabled(!folder.isReadable || licenceRefusal != nil)
        } footer: {
          if let refusal {
            Text(refusal).font(.caption).foregroundStyle(.secondary)
          } else if let licenceRefusal {
            HStack(alignment: .firstTextBaseline) {
              Text(licenceRefusal)
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button(buyTitle, action: onBuy)
                .controlSize(.small)
            }
          }
        }

        if folder.isTemporary {
          Section {
            VStack(alignment: .leading, spacing: 8) {
              Text(folder.preview.headline)
                .font(.headline)
                .monospacedDigit()
              if !folder.preview.forecast.isEmpty {
                ForecastList(groups: folder.preview.forecast)
                  .padding(.horizontal, -8)
              }
            }
          } header: {
            Text("What goes")
          }

          Section {
            Picker(
              "Rule",
              selection: Binding(get: { settings.rule }, set: { rule in change { $0.rule = rule } })
            ) {
              Text("Not added or changed for a while").tag(Rule.age)
              Text("The folder is over a size").tag(Rule.size)
              Text("The disk is nearly full").tag(Rule.automatic)
              Text("The Mac restarts").tag(Rule.emptyOnRestart)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            switch settings.rule {
            case .age:
              LabeledContent("Older than") {
                number(settings.maxAgeDays, unit: "days", range: 1...3650) { value in
                  change { $0.maxAgeDays = value }
                }
              }
            case .size:
              LabeledContent("Over") {
                number(
                  Int((Double(settings.sizeLimit) / 1e9).rounded()), unit: "GB", range: 1...100_000
                ) { value in
                  change { $0.sizeLimit = Int64(value) * 1_000_000_000 }
                }
              }
            case .automatic, .emptyOnRestart:
              EmptyView()
            }
          } header: {
            Text("Clear things when")
          } footer: {
            Text(rulesFooter).font(.caption).foregroundStyle(.secondary)
          }

          Section {
            Picker(
              "Cleared items",
              selection: Binding(
                get: { settings.disposal },
                set: { disposal in change { $0.chosenDisposal = disposal } }
              )
            ) {
              Text("Move to \(binName)").tag(Disposal.bin)
              Text("Delete Permanently").tag(Disposal.delete)
            }
            .disabled(settings.rule == .automatic)
          } footer: {
            Text(
              settings.disposal == .delete
                ? "Frees the space now. Can't be put back."
                : "You can put them back from DirBuff or the \(binName)."
            )
            .font(.caption)
            .foregroundStyle(
              settings.disposal == .delete ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)
            )
          }
        }
      }
      .formStyle(.grouped)
    }
    .alert(
      "Delete cleared items permanently?",
      isPresented: Binding(
        get: { deleteToConfirm != nil }, set: { if !$0 { deleteToConfirm = nil } }),
      presenting: deleteToConfirm
    ) { next in
      Button("Delete Permanently", role: .destructive) { onChangeSettings(next) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("They won't go to the \(binName) and can't be put back.")
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(nsImage: folderIcon(atPath: folder.path))
        .resizable()
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(folder.name)
          .font(.title2)
          .fontWeight(.semibold)
          .lineLimit(1)
        Text(folder.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer()
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 20)
    .padding(.top, 20)
    .padding(.bottom, 8)
  }

  /// Why the folder can't be made Temporary, if it can't.
  private var refusal: String? {
    if !folder.isReadable {
      return "DirBuff can't read this folder. It may be on a drive that isn't connected."
    }
    return nil
  }

  private var rulesFooter: String {
    switch settings.rule {
    case .age:
      "An item's age counts from when it was added or last changed, whichever is later."
    case .size: "The oldest items go first, until the folder fits."
    case .automatic:
      "The oldest items go first, deleted permanently: moving to the \(binName) frees no space."
    case .emptyOnRestart: "Everything there before a restart goes at the first clean-up after."
    }
  }

  /// Applies an edit, asking first when it would start deleting permanently: choosing Delete
  /// Permanently, or the disk rule, which always deletes.
  private func change(_ edit: (inout TemporarySettings) -> Void) {
    var next = settings
    edit(&next)
    if next.disposal == .delete, settings.disposal != .delete {
      deleteToConfirm = next
    } else {
      onChangeSettings(next)
    }
  }

  private func number(
    _ value: Int,
    unit: String,
    range: ClosedRange<Int>,
    set: @escaping (Int) -> Void
  ) -> some View {
    let binding = Binding(
      get: { value },
      set: { set(min(max($0, range.lowerBound), range.upperBound)) }
    )
    return HStack(spacing: 6) {
      TextField(unit, value: binding, format: .number)
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 56)
      Text(unit).foregroundStyle(.secondary)
      Stepper(unit, value: binding, in: range).labelsHidden()
    }
  }
}
