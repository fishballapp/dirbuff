import DirBuffCore
import SwiftUI

/// The card by a folder Temporary was just dropped on: what it will do there, its Age as a pop-up
/// that changes the folder's setting at once, with Undo, which takes it straight back off, and Done.
public struct AddedBuffCard: View {
  let folderName: String
  let folderPath: String
  let binName: String
  let disposal: Disposal
  let onChangeMaxAge: (Int) -> Void
  let onUndo: () -> Void
  let onDone: () -> Void

  @State private var maxAgeDays: Int

  /// - Parameters:
  ///   - maxAgeDays: The folder's Age, which a buff that was just added has from its defaults.
  ///   - disposal: What becomes of its things, from the same defaults.
  public init(
    folderName: String,
    folderPath: String,
    binName: String,
    maxAgeDays: Int = TemporarySettings.defaultMaxAgeDays,
    disposal: Disposal = .bin,
    onChangeMaxAge: @escaping (Int) -> Void,
    onUndo: @escaping () -> Void,
    onDone: @escaping () -> Void
  ) {
    self.folderName = folderName
    self.folderPath = folderPath
    self.binName = binName
    self.disposal = disposal
    self._maxAgeDays = State(initialValue: maxAgeDays)
    self.onChangeMaxAge = onChangeMaxAge
    self.onUndo = onUndo
    self.onDone = onDone
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        BuffSymbol(.temporary, size: .card)
          .foregroundStyle(Palette.ink)
        HStack(spacing: 5) {
          Text("\(Buff.temporary.name) is on")
            .font(.headline)
          FolderPill(folderName, path: folderPath)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Text("Files are cleared after")
          Picker("Files are cleared after", selection: maxAgeBinding) {
            ForEach(TemporarySettings.ageDayChoices(including: maxAgeDays), id: \.self) {
              Text(days($0)).tag($0)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
        Text(disposal.addedLine(binName: binName))
      }
      .font(.subheadline)
      .foregroundStyle(Palette.inkSecondary)
      .monospacedDigit()

      HStack(spacing: 6) {
        Spacer(minLength: 0)
        Button("Undo", action: onUndo)
        Button("Done", action: onDone)
          .buttonStyle(.borderedProminent)
          .tint(Palette.accentBlue)
          .keyboardShortcut(.defaultAction)
      }
    }
    .controlSize(.small)
    .foregroundStyle(Palette.ink)
    .padding(.top, 14)
    .padding(.horizontal, 14)
    .padding(.bottom, 12)
    .frame(width: 268)
  }

  private var maxAgeBinding: Binding<Int> {
    Binding(
      get: { maxAgeDays },
      set: { days in
        maxAgeDays = days
        onChangeMaxAge(days)
      })
  }
}
