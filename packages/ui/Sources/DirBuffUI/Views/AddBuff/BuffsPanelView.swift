import SwiftUI

/// The floating Buffs panel's content, what + Buff becomes torn off: a piece per buff, and a line
/// on where they go.
public struct BuffsPanelView: View {
  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 8) {
        ForEach(Buff.allCases, id: \.self) { buff in
          BuffPiece(buff)
        }
      }
      .padding(12)

      Divider()

      Text("Drag onto a folder, here or in Finder")
        .font(.subheadline)
        .foregroundStyle(Palette.inkTertiary)
        .padding(.top, 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
    .frame(width: 236)
    .background(Palette.paper)
  }
}
