import SwiftUI

/// A clickable row, highlighted under the pointer like a menu item: folder rows, forecast groups.
struct MenuRowStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    MenuRow(configuration: configuration)
  }

  private struct MenuRow: View {
    var configuration: ButtonStyle.Configuration
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(.rect)
        .background(
          isHovered || configuration.isPressed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
          in: .rect(cornerRadius: 6)
        )
        .onHover { isHovered = $0 }
    }
  }
}
