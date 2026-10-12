import AppKit
import SwiftUI

/// Forecast groups as both windows show them, under what happens to them: "Move to Bin", or
/// "Delete Permanently" in red, so permanent deletion never reads as part of an undoable section.
/// A group is two lines, when and how much, then which items; clicking it shows them in Finder,
/// selected. Rows are menu rows, so the caller bleeds the list 8 pt into its inset.
struct ForecastList: View {
  var groups: [ForecastGroup]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(sections, id: \.[0].id) { section in
        VStack(alignment: .leading, spacing: 2) {
          Text(section[0].action)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(
              section[0].isPermanent ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)
            )
            .padding(.horizontal, 8)
          ForEach(section) { group in
            Button {
              NSWorkspace.shared.activateFileViewerSelecting(group.items)
            } label: {
              row(group)
            }
            .buttonStyle(MenuRowStyle())
            .help("Show in Finder")
          }
        }
      }
    }
  }

  /// Consecutive groups with the same action; the groups come sorted by action first.
  private var sections: [[ForecastGroup]] {
    groups.reduce(into: []) { sections, group in
      if let last = sections.last?.last, last.action == group.action {
        sections[sections.count - 1].append(group)
      } else {
        sections.append([group])
      }
    }
  }

  private func row(_ group: ForecastGroup) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(alignment: .firstTextBaseline) {
        Text(group.when).fontWeight(.semibold).monospacedDigit()
        Spacer()
        Text("\(items(group.names.count)) · \(group.totalSize)")
          .font(.callout)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Text(names(group.names))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  /// "invoice.pdf, zoom_installer.pkg and 2 more".
  private func names(_ names: [String]) -> String {
    let shown = names.prefix(2).joined(separator: ", ")
    return names.count > 2 ? "\(shown) and \(names.count - 2) more" : shown
  }
}
