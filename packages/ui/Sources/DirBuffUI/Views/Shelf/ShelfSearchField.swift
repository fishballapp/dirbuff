import AppKit
import SwiftUI

/// Fixed-width native `NSSearchField` for the toolbar ("Filter folders by name", 210 pt).
/// SwiftUI's `.searchable` collapses into an icon button at narrower toolbar widths on macOS 26,
/// whereas the shelf keeps its 210 pt filter field visible in place.
struct ShelfSearchField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String = "Filter folders by name"

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = placeholder
    field.sendsSearchStringImmediately = true
    field.sendsWholeSearchString = false
    field.delegate = context.coordinator
    field.setAccessibilityLabel(placeholder)
    return field
  }

  func updateNSView(_ nsView: NSSearchField, context: Context) {
    context.coordinator.text = $text
    if nsView.placeholderString != placeholder {
      nsView.placeholderString = placeholder
    }
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var text: Binding<String>

    init(text: Binding<String>) {
      self.text = text
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSSearchField else { return }
      if text.wrappedValue != field.stringValue {
        text.wrappedValue = field.stringValue
      }
    }
  }
}
