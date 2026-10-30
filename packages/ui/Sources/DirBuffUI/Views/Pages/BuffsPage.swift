import SwiftUI

/// The Buffs page: every buff as a card, two to a row. A card drags onto a folder in the sidebar,
/// onto a tile, or out to a folder in Finder; its pop-up adds it to a folder without dragging, and
/// its folder pills open the folders that wear it.
public struct BuffsPage: View {
  public var state: BuffsPageState
  public var actions: ShelfActions
  public var onOpenFolder: (Int64) -> Void

  public init(
    state: BuffsPageState,
    actions: ShelfActions = ShelfActions(),
    onOpenFolder: @escaping (Int64) -> Void = { _ in }
  ) {
    self.state = state
    self.actions = actions
    self.onOpenFolder = onOpenFolder
  }

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Drag a buff onto a folder in the sidebar, a tile or a folder in Finder.")
          .foregroundStyle(Palette.inkSecondary)
          .padding(.horizontal, 2)
        LazyVGrid(
          columns: [
            GridItem(.flexible(), spacing: 20, alignment: .top),
            GridItem(.flexible(), spacing: 20, alignment: .top),
          ],
          alignment: .leading,
          spacing: 20
        ) {
          ForEach(state.cards) { card in
            BuffsPageCardView(card: card, actions: actions, onOpenFolder: onOpenFolder)
          }
        }
      }
      .padding(32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.paper)
    .navigationTitle("Buffs")
    .navigationSubtitle(state.subtitle)
  }
}

/// One buff's card: its symbol in Accent Blue, its name in caps, what it does, and for a buff that
/// has shipped, the folders that wear it, its starting setting and Add to Folder.
private struct BuffsPageCardView: View {
  var card: BuffsPageCard
  var actions: ShelfActions
  var onOpenFolder: (Int64) -> Void

  private var buff: Buff { card.buff }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if buff.isAvailable {
        about.buffDragSource(buff)
      } else {
        about
      }
      if buff.isAvailable {
        Palette.rule
          .frame(height: 1)
          .padding(.leading, 70)
          .padding(.trailing, 22)
        wornBy
          .padding(.leading, 70)
          .padding(.trailing, 22)
          .padding(.top, 14)
        foot
          .padding(.leading, 70)
          .padding(.trailing, 22)
          .padding(.top, 14)
          .padding(.bottom, 18)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .liftedCard()
  }

  /// The part that drags: the symbol, the name and what it does.
  private var about: some View {
    HStack(alignment: .top, spacing: 18) {
      BuffSymbol(buff, size: .buffsPage)
        .foregroundStyle(buff.isAvailable ? Palette.accentBlue : Palette.quiet)
        .frame(width: 30, alignment: .leading)
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          BuffName(buff, size: .card)
            .foregroundStyle(buff.isAvailable ? Palette.ink : Palette.inkTertiary)
          if !buff.isAvailable {
            SoonCapsule()
          }
          Spacer(minLength: 0)
          if buff.isAvailable {
            Image(systemName: "circle.grid.2x3.fill")
              .font(.system(size: 9))
              .foregroundStyle(Palette.quiet)
              .help("Drag onto a folder")
              .accessibilityHidden(true)
          }
        }
        Text(buff.summary)
          .foregroundStyle(buff.isAvailable ? Palette.inkSecondary : Palette.inkTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.top, 20)
    .padding(.horizontal, 22)
    .padding(.bottom, buff.isAvailable ? 16 : 20)
    .contentShape(.rect)
  }

  /// "On 5 folders", then a pill per folder, each opening it.
  private var wornBy: some View {
    SentenceFlow(wordSpacing: 6, lineSpacing: 6) {
      Text(card.wornBy)
        .fontWeight(.semibold)
        .foregroundStyle(Palette.ink)
        .monospacedDigit()
      ForEach(card.folders) { row in
        Button {
          onOpenFolder(row.id)
        } label: {
          FolderPill(row.title, path: row.folder.path)
        }
        .buttonStyle(.plain)
        .help("Open \(row.title)")
      }
    }
  }

  private var foot: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      if let startsAs = card.startsAs {
        Text(startsAs)
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
      }
      Spacer(minLength: 0)
      Menu("Add to Folder") {
        ForEach(card.targets) { target in
          Button {
            actions.add(buff, to: target.folderID)
          } label: {
            Text(target.title)
            if let subtitle = target.subtitle {
              Text(subtitle)
            }
          }
          .disabled(!target.isEnabled)
        }
        if !card.targets.isEmpty {
          Divider()
        }
        Button("Other Folder…") {
          actions.chooseFolderForBuff(buff)
        }
      }
      .fixedSize()
      .disabled(!card.canAdd)
    }
  }
}
