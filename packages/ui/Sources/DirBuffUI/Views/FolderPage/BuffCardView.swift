import DirBuffCore
import SwiftUI

/// One buff on a folder's page: the head (its symbol, its name and its buttons), the summary (a
/// large status line, one sentence of what happens next, and a gauge), and its setting as a
/// sentence below a Rule.
struct BuffCardView: View {
  var card: BuffCard
  var folder: FolderState
  var binName: String
  var actions: ShelfActions
  var pageActions: FolderPageActions
  var onChangeSettings: (TemporarySettings) -> Void

  @Environment(\.colorScheme) private var colorScheme

  /// Where the summary starts: past the symbol and the gap after it, so its lines start under the
  /// buff's name.
  private static let summaryInset: CGFloat = 66

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        head
        summary
      }
      .background(isNeedingYou ? Palette.amberTint : .clear)

      Palette.rule.frame(height: 1)
      TemporarySettingView(
        settings: card.settings,
        meaning: card.meaning,
        folderName: folder.name,
        binName: binName,
        onChange: onChangeSettings
      )
      .padding(.leading, Self.summaryInset)
      .padding(.trailing, 22)
      .padding(.top, 14)
      .padding(.bottom, 18)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.card)
    .clipShape(.rect(cornerRadius: Metrics.tileRadius))
    .overlay {
      RoundedRectangle(cornerRadius: Metrics.tileRadius)
        .strokeBorder(
          isNeedingYou
            ? Palette.amberEdge : Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.14),
          lineWidth: isNeedingYou ? 1 : 0.5)
    }
    .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.14), radius: 8, y: 4)
  }

  private var isNeedingYou: Bool {
    if case .needsYou = card.state { return true }
    return false
  }

  private var head: some View {
    HStack(spacing: 12) {
      BuffSymbol(card.buff, size: .card)
        .foregroundStyle(usesQuietSymbol ? Palette.quiet : Palette.ink)
        .overlay(alignment: .bottomTrailing) {
          if isNeedingYou {
            NeedsYouBadge(size: 16)
              .offset(x: 6, y: 5)
          }
        }
      BuffName(card.buff, size: .card)
        .foregroundStyle(isNeedingYou ? Palette.amberText : Palette.ink)
      if case .paused(let reason) = card.state {
        PausedPill(reason: reason, onOpenLicence: actions.openLicenceSettings)
      }
      Spacer(minLength: 12)
      HStack(spacing: 8) {
        if card.canShowFiles {
          Button("What Goes Next…") { pageActions.showFiles(folder.id) }
        }
        // It asks first, so a quiet icon is enough.
        GhostIconButton("Take Off \(card.buff.name)", systemImage: "xmark") {
          actions.takeOff(folder.id, card.buff)
        }
      }
    }
    .padding(.top, 18)
    .padding(.horizontal, 22)
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 0) {
      sentence(card.headline)
        .font(.system(size: 21, weight: .semibold))
        .foregroundStyle(isNeedingYou ? Palette.amberText : Palette.ink)
        .monospacedDigit()

      if let detail = card.detail {
        sentence(detail)
          .font(.body)
          .foregroundStyle(Palette.inkSecondary)
          .monospacedDigit()
          .frame(maxWidth: 620, alignment: .leading)
          .padding(.top, 6)
      }

      if let gauge = card.gauge {
        GaugeView(gauge: gauge)
          .padding(.top, 12)
      }

      if case .needsYou(let fix) = card.state {
        HStack(spacing: 8) {
          Button(fix.title) { actions.fix(folder.id, fix) }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accentBlue)
          if fix == .locate {
            Button("Remove from DirBuff") { actions.removeFolder(folder.id) }
          }
        }
        .padding(.top, 14)
      }
    }
    .padding(.leading, Self.summaryInset)
    .padding(.trailing, 22)
    .padding(.top, 14)
    .padding(.bottom, 20)
  }

  /// The words, with the folder's pill before or after them when they name it.
  @ViewBuilder
  private func sentence(_ sentence: FolderSentence) -> some View {
    switch sentence.pill {
    case .none:
      Text(sentence.text)
        .fixedSize(horizontal: false, vertical: true)
    case .before:
      // Word by word, so the lines after the first start under the pill, not beside it.
      SentenceFlow(lineSpacing: 2) {
        FolderPill(folder.name, path: folder.path)
        ForEach(Array(sentence.text.split(separator: " ").enumerated()), id: \.offset) {
          Text($0.element)
        }
      }
    case .after:
      HStack(alignment: .center, spacing: 8) {
        Text(sentence.text)
        FolderPill(folder.name, path: folder.path)
      }
    }
  }

  private var usesQuietSymbol: Bool {
    switch card.state {
    case .paused: true
    case .atRest, .working, .needsYou: false
    }
  }
}

/// A 360 pt bar and its figure: how full the folder is, or how far a clean-up has got.
private struct GaugeView: View {
  var gauge: Gauge

  var body: some View {
    HStack(spacing: 12) {
      ZStack(alignment: .leading) {
        Capsule().fill(Palette.ruleStrong)
        Capsule()
          .fill(gauge.kind == .progress ? Palette.accentBlue : Palette.inkSecondary)
          .frame(width: max(6, 360 * gauge.fraction))
      }
      .frame(width: 360, height: 6)
      Text(gauge.figure)
        .font(.subheadline)
        .foregroundStyle(Palette.inkTertiary)
        .monospacedDigit()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(gauge.figure)
    .accessibilityValue(Text(gauge.fraction, format: .percent.precision(.fractionLength(0))))
  }
}
