import DirBuffCore
import SwiftUI

/// Temporary's one setting as a sentence with pop-up buttons in it: "Files go when [they're older
/// than 14 days], and [move to the Bin].", with a line under it on what that means. A choice takes
/// effect at once, except that starting to delete permanently asks first.
struct TemporarySettingView: View {
  var settings: TemporarySettings
  var meaning: String
  var folderName: String
  var binName: String
  var onChange: (TemporarySettings) -> Void

  /// The amount a "…" choice asks for, while its sheet is open.
  @State private var amount: Amount?
  /// Settings that would start deleting permanently, waiting for the user to confirm.
  @State private var deleteToConfirm: TemporarySettings?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      SentenceFlow {
        words("Files go when")
        SettingPopUp(entries: ruleEntries, selection: ruleSelection, onChoose: chooseRule)
          .accessibilityLabel("Files go when")
        if settings.rule == .size || settings.rule == .automatic {
          Text(",").hugsPrevious()
          words("oldest first,")
        } else {
          Text(",").hugsPrevious()
        }
        words("and")
        if settings.rule == .automatic {
          // The disk rule always deletes: binning frees no space.
          words("are deleted permanently")
        } else {
          SettingPopUp(
            entries: disposalEntries, selection: settings.disposal, onChoose: chooseDisposal
          )
          .accessibilityLabel("And what happens to them")
        }
        Text(".").hugsPrevious()
      }
      .foregroundStyle(Palette.ink)

      Text(meaning)
        .font(.subheadline)
        .foregroundStyle(Palette.inkTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .sheet(item: $amount) { amount in
      AmountSheet(amount: amount, onCancel: { self.amount = nil }) { value in
        self.amount = nil
        change {
          switch amount {
          case .age:
            $0.rule = .age
            $0.maxAgeDays = value
          case .size:
            $0.rule = .size
            $0.sizeLimit = Int64(value) * 1_000_000_000
          }
        }
      }
    }
    .alert(
      "Delete files from \(folderName) permanently?",
      isPresented: Binding(
        get: { deleteToConfirm != nil }, set: { if !$0 { deleteToConfirm = nil } }),
      presenting: deleteToConfirm
    ) { next in
      Button("Delete Permanently") { onChange(next) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("They won't go to the \(binName), so they can't be put back.")
    }
  }

  /// One `Text` per word, so the sentence can wrap between them.
  private func words(_ text: String) -> some View {
    ForEach(Array(text.split(separator: " ").enumerated()), id: \.offset) { _, word in
      Text(word)
    }
  }

  // MARK: - The rule

  private enum RuleChoice: Hashable {
    case age(days: Int)
    case otherAge
    case size
    case otherSize
    case emptyOnRestart
    case automatic
  }

  private static let ageChoices = [7, 14, 30, 90]

  private var ruleSelection: RuleChoice {
    switch settings.rule {
    case .age: .age(days: settings.maxAgeDays)
    case .size: .size
    case .emptyOnRestart: .emptyOnRestart
    case .automatic: .automatic
    }
  }

  private var ruleEntries: [SettingPopUp<RuleChoice>.Entry] {
    let ages = Set(Self.ageChoices + (settings.rule == .age ? [settings.maxAgeDays] : []))
    var entries: [SettingPopUp<RuleChoice>.Entry] = ages.sorted().map {
      .choice(.age(days: $0), title: "they're older than \(days($0))")
    }
    entries.append(.choice(.otherAge, title: "they're older than…"))
    entries.append(.separator)
    if settings.rule == .size {
      entries.append(.choice(.size, title: "the folder is over \(bytes(settings.sizeLimit))"))
    }
    entries.append(.choice(.otherSize, title: "the folder is over…"))
    entries.append(.choice(.emptyOnRestart, title: "the Mac restarts"))
    entries.append(.separator)
    entries.append(
      .choice(
        .automatic, title: "the disk is nearly full",
        subtitle: "Deletes permanently, no \(binName)"))
    return entries
  }

  private func chooseRule(_ choice: RuleChoice) {
    switch choice {
    case .age(let days):
      change {
        $0.rule = .age
        $0.maxAgeDays = days
      }
    case .otherAge:
      amount = .age(settings.maxAgeDays)
    case .size:
      break
    case .otherSize:
      amount = .size(gigabytes: Int((Double(settings.sizeLimit) / 1e9).rounded()))
    case .emptyOnRestart:
      change { $0.rule = .emptyOnRestart }
    case .automatic:
      change { $0.rule = .automatic }
    }
  }

  // MARK: - Where files go

  private var disposalEntries: [SettingPopUp<Disposal>.Entry] {
    [
      .choice(.bin, title: "move to the \(binName)"),
      .separator,
      .choice(
        .delete, title: "are deleted permanently",
        subtitle: "Frees the space at once. Can't be put back."),
    ]
  }

  private func chooseDisposal(_ disposal: Disposal) {
    change { $0.chosenDisposal = disposal }
  }

  /// Applies an edit, asking first when it would start deleting permanently: choosing to delete, or
  /// the disk rule, which always deletes.
  private func change(_ edit: (inout TemporarySettings) -> Void) {
    var next = settings
    edit(&next)
    guard next != settings else { return }
    if next.disposal == .delete, settings.disposal != .delete {
      deleteToConfirm = next
    } else {
      onChange(next)
    }
  }
}

/// An amount a rule asks for: the Age rule's days, or the Size rule's limit.
private enum Amount: Identifiable {
  case age(Int)
  case size(gigabytes: Int)

  var id: String {
    switch self {
    case .age: "age"
    case .size: "size"
    }
  }

  var value: Int {
    switch self {
    case .age(let days): days
    case .size(let gigabytes): gigabytes
    }
  }

  var prompt: String {
    switch self {
    case .age: "Files go when they're older than"
    case .size: "Files go when the folder is over"
    }
  }

  var unit: String {
    switch self {
    case .age: "days"
    case .size: "GB"
    }
  }

  var range: ClosedRange<Int> {
    switch self {
    case .age: 1...3650
    case .size: 1...100_000
    }
  }
}

/// Asks for a rule's amount, finishing the sentence: "Files go when they're older than [45]
/// days".
private struct AmountSheet: View {
  var amount: Amount
  var onCancel: () -> Void
  var onChange: (Int) -> Void

  @State private var value: Int

  init(amount: Amount, onCancel: @escaping () -> Void, onChange: @escaping (Int) -> Void) {
    self.amount = amount
    self.onCancel = onCancel
    self.onChange = onChange
    self._value = State(initialValue: amount.value)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(spacing: 6) {
        Text(amount.prompt)
        TextField(amount.unit, value: $value, format: .number)
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 64)
        Text(amount.unit)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Change") {
          onChange(min(max(value, amount.range.lowerBound), amount.range.upperBound))
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .fixedSize()
  }
}
