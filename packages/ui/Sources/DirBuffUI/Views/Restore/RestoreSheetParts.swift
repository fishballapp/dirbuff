import SwiftUI

/// What every restore sheet shares: Backup's symbol, a heading and its sentences, a body, and the
/// buttons trailing, as the sign-in sheet draws them.
struct RestoreSheetShell<Heading: View, Body: View, Buttons: View>: View {
  var width: CGFloat
  @ViewBuilder var heading: Heading
  var sentences: [String]
  @ViewBuilder var content: Body
  @ViewBuilder var buttons: Buttons

  init(
    width: CGFloat = 480, sentences: [String] = [],
    @ViewBuilder heading: () -> Heading, @ViewBuilder content: () -> Body = { EmptyView() },
    @ViewBuilder buttons: () -> Buttons
  ) {
    self.width = width
    self.sentences = sentences
    self.heading = heading()
    self.content = content()
    self.buttons = buttons()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 14) {
        BuffSymbol(.backup, size: .card)
          .foregroundStyle(Palette.accentBlue)
          .padding(.top, 2)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 6) {
          heading
            .font(.headline)
            .foregroundStyle(Palette.ink)
          ForEach(sentences, id: \.self) { sentence in
            Text(sentence)
              .foregroundStyle(Palette.inkSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      content
        .padding(.leading, 46)
      HStack(spacing: 8) {
        Spacer(minLength: 8)
        buttons
      }
    }
    .padding(20)
    .frame(width: width)
    .background(Palette.paper)
  }
}

/// A bar that fills as the restore's bytes arrive, with its figures under it, in the popover's
/// own bar and type.
struct RestoreProgressBar: View {
  var run: RestoreRun

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Capsule()
        .fill(Palette.ruleStrong)
        .frame(height: 6)
        .overlay(alignment: .leading) {
          GeometryReader { bar in
            Capsule()
              .fill(Palette.accentBlue)
              .frame(width: max(6, bar.size.width * run.fraction))
          }
        }
      Text(run.counts ?? "Getting ready…")
        .font(.subheadline)
        .foregroundStyle(Palette.inkTertiary)
        .monospacedDigit()
        .frame(height: 16, alignment: .leading)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Restoring \(run.folderName)")
    .accessibilityValue(run.counts ?? "")
  }
}

/// The password prompt for a backup that has one: the field, and plainly when the last try was
/// wrong. The password is the caller's to use; nothing here keeps it.
struct RestorePasswordForm: View {
  var ask: PasswordAsk
  @Binding var password: String
  var onSubmit: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SecureField("Password", text: $password)
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .disabled(ask.isChecking)
        .onSubmit(onSubmit)
        .accessibilityLabel("Password")
      if ask.isChecking {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Opening the backup…")
            .font(.subheadline)
            .foregroundStyle(Palette.inkTertiary)
        }
      } else if ask.isWrong {
        Text(ask.wrongSentence)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(Palette.ink)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// A restore problem in a sheet: what happened, what to do, with no colour but Ink: a restore
/// that couldn't happen asks for a decision, and amber is for what needs the user in the app.
struct RestoreProblemText: View {
  var problem: RestoreProblem

  var body: some View {
    Text(problem.message)
      .foregroundStyle(Palette.inkSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
