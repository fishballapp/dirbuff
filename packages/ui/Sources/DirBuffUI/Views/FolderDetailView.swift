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
  public var onSetTemporary: (Bool) -> Void
  public var onChangeSettings: (TemporarySettings) -> Void
  public var onBuy: () -> Void

  @State private var isConfirmingDelete = false

  private var settings: TemporarySettings { folder.settings }

  public init(
    folder: MainFolder,
    binName: String = SystemBin.name,
    licenceRefusal: String? = nil,
    onSetTemporary: @escaping (Bool) -> Void = { _ in },
    onChangeSettings: @escaping (TemporarySettings) -> Void = { _ in },
    onBuy: @escaping () -> Void = {}
  ) {
    self.folder = folder
    self.binName = binName
    self.licenceRefusal = licenceRefusal
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
              Button("Buy DirBuff…", action: onBuy)
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
            rule(
              "Not added or changed for", \.maxAgeDays,
              default: TemporarySettings.defaultMaxAgeDays
            ) { days in
              number(days, unit: "days", range: 1...3650) { value in
                change { $0.maxAgeDays = value }
              }
            }
            rule("The folder is over", \.sizeLimit, default: 10_000_000_000) { limit in
              number(Int((Double(limit) / 1e9).rounded()), unit: "GB", range: 1...100_000) {
                value in
                change { $0.sizeLimit = Int64(value) * 1_000_000_000 }
              }
            }
            Toggle("The disk is nearly full", isOn: flag(\.automatic))
              .toggleStyle(.checkbox)
              .disabled(settings.disposal == .bin)
              .help("Needs Delete Permanently: moving to the \(binName) frees no space.")
            Toggle("The Mac restarts", isOn: flag(\.emptyOnRestart)).toggleStyle(.checkbox)
          } header: {
            Text("Clear an item when")
          } footer: {
            Text(rulesFooter).font(.caption).foregroundStyle(.secondary)
          }

          Section {
            Picker(
              "Cleared items",
              selection: Binding(
                get: { settings.disposal },
                set: { disposal in
                  switch disposal {
                  case .delete:
                    isConfirmingDelete = true
                  case .bin:
                    change {
                      $0.disposal = .bin
                      $0.automatic = false
                    }
                  }
                }
              )
            ) {
              Text("Move to \(binName)").tag(Disposal.bin)
              Text("Delete Permanently").tag(Disposal.delete)
            }
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
    .alert("Delete cleared items permanently?", isPresented: $isConfirmingDelete) {
      Button("Delete Permanently", role: .destructive) {
        change { $0.disposal = .delete }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("They won't go to the \(binName) and can't be put back.")
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
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
    let anyRule =
      settings.maxAgeDays != nil || settings.sizeLimit != nil || settings.automatic
      || settings.emptyOnRestart
    guard anyRule else { return "With no rule on, nothing is cleared." }
    if settings.sizeLimit != nil || settings.automatic {
      return "Size and disk space clear the oldest items first."
    }
    return "An item's age counts from when it was added or last changed, whichever is later."
  }

  private func change(_ edit: (inout TemporarySettings) -> Void) {
    var next = settings
    edit(&next)
    onChangeSettings(next)
  }

  private func rule<Value, Field: View>(
    _ label: String,
    _ keyPath: WritableKeyPath<TemporarySettings, Value?>,
    default: Value,
    @ViewBuilder field: (Value) -> Field
  ) -> some View {
    HStack {
      Toggle(
        label,
        isOn: Binding(
          get: { settings[keyPath: keyPath] != nil },
          set: { isOn in change { $0[keyPath: keyPath] = isOn ? `default` : nil } }
        )
      )
      .toggleStyle(.checkbox)
      Spacer()
      field(settings[keyPath: keyPath] ?? `default`)
        .disabled(settings[keyPath: keyPath] == nil)
    }
  }

  private func flag(_ keyPath: WritableKeyPath<TemporarySettings, Bool>) -> Binding<Bool> {
    Binding(
      get: { settings[keyPath: keyPath] },
      set: { isOn in change { $0[keyPath: keyPath] = isOn } }
    )
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
