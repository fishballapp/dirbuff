import DirBuffUI
import SwiftUI

/// One sheet of the design's building blocks: the palette, buff names and symbols at every size,
/// and the mark in each state, to check them against the design reference.
struct FoundationSheet: View {
  private let swatches: [(String, Color)] = [
    ("Accent Blue", Palette.accentBlue), ("Blue Tint", Palette.blueTint),
    ("Amber", Palette.amber), ("Amber Text", Palette.amberText),
    ("Amber Tint", Palette.amberTint), ("Amber Edge", Palette.amberEdge),
    ("Paper", Palette.paper), ("Card", Palette.card), ("Well", Palette.well),
    ("Ink", Palette.ink), ("Ink Secondary", Palette.inkSecondary),
    ("Ink Tertiary", Palette.inkTertiary), ("Rule", Palette.rule),
    ("Rule Strong", Palette.ruleStrong), ("Quiet", Palette.quiet),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(96)), count: 5), spacing: 10) {
        ForEach(swatches, id: \.0) { name, color in
          VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6).fill(color).frame(height: 32)
              .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.rule))
            Text(name).font(.caption).foregroundStyle(Palette.inkSecondary)
          }
        }
      }
      HStack(spacing: 12) {
        FolderPill("Downloads", path: NSHomeDirectory() + "/Downloads")
        GhostIconButton("Put Back", systemImage: GhostIconButton.putBackSymbol) {}
        GhostIconButton("Show in Finder", systemImage: GhostIconButton.finderSymbol) {}
        GhostIconButton("History", systemImage: GhostIconButton.historySymbol) {}
      }
      ForEach(Buff.allCases, id: \.self) { buff in
        HStack(alignment: .center, spacing: 16) {
          ForEach(
            [BuffSymbol.Size.addBuff, .card, .row, .menu, .switcher, .sidebar], id: \.self
          ) { size in
            BuffSymbol(buff, size: size)
          }
          .foregroundStyle(buff.isAvailable ? Palette.accentBlue : Palette.quiet)
          BuffName(buff, size: .row)
          BuffName(buff, size: .piece)
          BuffName(buff, size: .card)
          Text(buff.summary).foregroundStyle(Palette.inkSecondary)
        }
        .foregroundStyle(Palette.ink)
      }
      HStack(spacing: 20) {
        ForEach(MarkState.allCases, id: \.self) { state in
          VStack(spacing: 6) {
            Mark(state, size: 40)
            Mark(state, size: 20)
          }
        }
        NeedsYouBadge()
      }
      .padding(12)
      .background(Color(red: 0.31, green: 0.6, blue: 0.87))
    }
    .padding(24)
    .background(Palette.paper)
  }
}
