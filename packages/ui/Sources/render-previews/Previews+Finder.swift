import AppKit
import DirBuffCore
import DirBuffKit
import DirBuffUI
import SwiftUI

extension Samples {
  static let finderPlainMenu = FinderMenu.addBuff(
    folderName: "Scratch",
    isProtected: false,
    binName: binName
  )

  static let finderProtectedMenu = FinderMenu.addBuff(
    folderName: "Desktop",
    isProtected: true,
    binName: binName
  )

  static let finderBuffedMenu = FinderMenu.buffs(
    folderName: "Downloads",
    worn: [
      FinderBuff(
        buff: .temporary,
        setting: "Older than 14 days, to the Bin",
        nextEvent: "12 items go tomorrow \u{00b7} 1.3 GB"
      )
    ],
    binName: binName
  )

  static let finderNeedsYouMenu = FinderMenu.buffs(
    folderName: "Projects",
    worn: [
      FinderBuff(
        buff: .temporary,
        setting: "Nothing cleared for 3 days",
        nextEvent: "macOS took away access"
      )
    ],
    binName: binName
  )
}

/// Renders the Finder badge in its four states, from `Mark.badgeImage(for:)`.
struct FinderBadgesSheet: View {
  private let rows: [(MarkState, String, String)] = [
    (.needsYou, "Needs you", "The normal mark with an amber \"!\" at its lower right"),
    (.working, "Working", "A blue arc on the white rim and a smaller arm"),
    (.paused, "Paused", "An empty grey ring around a grey arm"),
    (.atRest, "At rest", "White disc, ink arm"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ForEach(rows, id: \.0) { state, title, caption in
        HStack(spacing: 14) {
          ZStack(alignment: .bottomLeading) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
              .resizable()
              .frame(width: 48, height: 48)
            Image(nsImage: Mark.badgeImage(for: state))
              .interpolation(.high)
              .frame(width: 20, height: 20)
          }
          Image(nsImage: Mark.badgeImage(for: state))
            .interpolation(.high)
            .frame(width: 20, height: 20)
            .padding(6)
            .background(
              RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.31, green: 0.6, blue: 0.87))
            )
          VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(Palette.ink)
            Text(caption).font(.subheadline).foregroundStyle(Palette.inkSecondary)
          }
        }
      }
    }
    .padding(20)
    .frame(width: 440, alignment: .leading)
    .background(Palette.paper)
  }
}

/// Renders a `FinderMenu` as Finder's context item and its submenu.
struct FinderMenuSheet: View {
  let menu: FinderMenu

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Text(menu.title)
            .font(.body)
            .foregroundStyle(.white)
          Spacer(minLength: 16)
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(Palette.accentBlue)
        )
      }
      .padding(5)
      .frame(width: 196)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(Palette.card)
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.rule))
      )

      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(menu.items.enumerated()), id: \.offset) { _, item in
          switch item.kind {
          case .separator:
            Divider().padding(.vertical, 4)
          case .sectionHeader:
            Text(item.title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(Palette.inkTertiary)
              .padding(.horizontal, 10)
              .padding(.top, 4)
              .padding(.bottom, 2)
          case .item:
            HStack(alignment: .top, spacing: 8) {
              if let buff = item.buff {
                BuffSymbol(buff, size: .menu)
                  .foregroundStyle(item.isEnabled ? Palette.ink : Palette.quiet)
                  .frame(width: 23, height: 16)
                  .padding(.top, 1)
              }
              VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                  .font(.body)
                  .foregroundStyle(item.isEnabled ? Palette.ink : Palette.inkTertiary)
                  .fixedSize(horizontal: true, vertical: false)
                if let subtitle = item.subtitle {
                  Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(item.isEnabled ? Palette.inkSecondary : Palette.quiet)
                    .fixedSize(horizontal: true, vertical: false)
                }
              }
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
          }
        }
      }
      .padding(6)
      .frame(width: 340, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(Palette.card)
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.rule))
      )
    }
    .padding(16)
    .background(Palette.paper)
  }
}

@MainActor
func finderPreviews() -> [Preview] {
  [
    ("finder-badges", AnyView(FinderBadgesSheet()), nil),
    ("finder-menu-add-buff", AnyView(FinderMenuSheet(menu: Samples.finderPlainMenu)), nil),
    (
      "finder-menu-add-buff-protected",
      AnyView(FinderMenuSheet(menu: Samples.finderProtectedMenu)),
      nil
    ),
    ("finder-menu-buffs", AnyView(FinderMenuSheet(menu: Samples.finderBuffedMenu)), nil),
  ]
}
