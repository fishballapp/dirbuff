import DirBuffKit
import SwiftUI

/// The window a licence key is pasted into. A failed activation stays open with the reason, so the
/// key can be corrected or a Mac freed without pasting again.
public struct KeyEntryView: View {
  @Binding public var key: String
  public var isActivating: Bool
  public var failure: PolarLicensing.Failure?
  public var onActivate: () -> Void
  public var onCancel: () -> Void
  public var onManageSubscription: () -> Void

  public init(
    key: Binding<String>,
    isActivating: Bool = false,
    failure: PolarLicensing.Failure? = nil,
    onActivate: @escaping () -> Void = {},
    onCancel: @escaping () -> Void = {},
    onManageSubscription: @escaping () -> Void = {}
  ) {
    self._key = key
    self.isActivating = isActivating
    self.failure = failure
    self.onActivate = onActivate
    self.onCancel = onCancel
    self.onManageSubscription = onManageSubscription
  }

  private var canActivate: Bool {
    !isActivating && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Enter Licence Key").font(.headline)
        Text("It's on the page that opened after you paid, and in your receipt email.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      TextField("DIRBUFF-…", text: $key)
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.roundedBorder)
        .disabled(isActivating)
        .onSubmit { if canActivate { onActivate() } }

      if let failure {
        VStack(alignment: .leading, spacing: 8) {
          Text(failure.message)
            .font(.callout)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
          if failure == .activationLimitReached {
            Button("Manage Subscription…", action: onManageSubscription)
              .controlSize(.small)
          }
        }
      }

      HStack(spacing: 8) {
        if isActivating {
          ProgressView().controlSize(.small)
        }
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Activate", action: onActivate)
          .keyboardShortcut(.defaultAction)
          .disabled(!canActivate)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}
