import AppKit
import SwiftUI

/// The system pop-up button for one part of a setting's sentence: the current choice, opening a
/// menu that can set options apart below separators and say under one what it costs. SwiftUI's
/// menu picker can't put a quiet line under an item, so this hosts `NSPopUpButton`, as wide as its
/// current title rather than its widest item, so it reads as part of the sentence.
struct SettingPopUp<Choice: Hashable>: View {
  enum Entry {
    case choice(Choice, title: String, subtitle: String? = nil)
    case separator
  }

  var entries: [Entry]
  var selection: Choice
  var onChoose: (Choice) -> Void

  var body: some View {
    PopUpButton(entries: entries, selection: selection, onChoose: onChoose)
      .frame(width: fittedWidth)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var selectedTitle: String {
    for case .choice(let choice, let title, _) in entries where choice == selection {
      return title
    }
    return ""
  }

  /// The title's width plus the bezel's insets and the arrows. `sizeToFit()` sizes the cell for a
  /// menu's state column too, which leaves a long empty run before the arrows.
  private var fittedWidth: CGFloat {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let title = (selectedTitle as NSString).size(withAttributes: [.font: font]).width
    return ceil(title) + Self.chrome
  }

  /// The bezel's leading inset, the gap before the arrows, the arrows and the trailing inset.
  private static var chrome: CGFloat { 38 }
}

private struct PopUpButton<Choice: Hashable>: NSViewRepresentable {
  var entries: [SettingPopUp<Choice>.Entry]
  var selection: Choice
  var onChoose: (Choice) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.target = context.coordinator
    button.action = #selector(Coordinator.choose(_:))
    return button
  }

  func updateNSView(_ button: NSPopUpButton, context: Context) {
    let menu = NSMenu()
    var selected: NSMenuItem?
    for entry in entries {
      switch entry {
      case .separator:
        menu.addItem(.separator())
      case .choice(let choice, let title, let subtitle):
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let subtitle {
          if #available(macOS 14.4, *) {
            item.subtitle = subtitle
          } else {
            item.toolTip = subtitle
          }
        }
        item.representedObject = AnyHashable(choice)
        menu.addItem(item)
        if choice == selection { selected = item }
      }
    }
    button.menu = menu
    button.select(selected)
    context.coordinator.onChoose = { item in
      guard let choice = (item.representedObject as? AnyHashable)?.base as? Choice else { return }
      // The button keeps showing the current setting until the change comes back as state; a
      // choice that asks for more (an amount, a confirmation) may never change it.
      button.select(selected)
      onChoose(choice)
    }
  }

  /// Takes the width the wrapper gives it, at the button's own height.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context)
    -> CGSize?
  {
    CGSize(
      width: proposal.width ?? button.intrinsicContentSize.width,
      height: button.intrinsicContentSize.height)
  }

  @MainActor
  final class Coordinator: NSObject {
    var onChoose: (NSMenuItem) -> Void = { _ in }

    @objc func choose(_ sender: NSPopUpButton) {
      guard let item = sender.selectedItem else { return }
      onChoose(item)
    }
  }
}
