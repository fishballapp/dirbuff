import SwiftUI

/// What letting go of a buff over a folder does: its tile, its sidebar row, or its page.
public enum BuffDropVerdict: Sendable, Equatable {
  /// It goes on: "Add Temporary to Scratch".
  case add(String)
  /// It doesn't, and why, in grey: "Downloads already wears Temporary".
  case refused(String)
  /// The folder is protected: it fades with "Protected" for as long as the buff is in the air.
  case protected

  /// Whether `buff` dropped on `folder` goes on, given the folder's "Add a Buff to …" items.
  public static func of(
    _ buff: Buff,
    on folder: FolderState,
    items: [AddBuffItem],
    mayClean: Bool
  ) -> BuffDropVerdict {
    if folder.wears(buff) { return .refused("\(folder.name) already wears \(buff.name)") }
    guard buff.isAvailable else { return .refused("\(buff.name) isn't ready yet") }
    guard mayClean else { return .refused("Every buff is paused") }
    if let reason = folder.unreachableReason { return .refused(reason) }
    // The items list every buff the folder doesn't wear; with the licence clear, only a protected
    // folder disables an available one.
    guard items.first(where: { $0.buff == buff })?.isEnabled == true else { return .protected }
    return .add("Add \(buff.name) to \(folder.name)")
  }

  var isAdding: Bool {
    if case .add = self { return true }
    return false
  }
}

extension View {
  /// Takes a buff dropped here onto `folder`, as `verdict` says, and lets the drag know which
  /// folder it's over.
  func buffDrop(
    on folderID: Int64,
    verdict: BuffDropVerdict?,
    onAdd: @escaping (Buff) -> Void
  ) -> some View {
    modifier(BuffDropModifier(folderID: folderID, verdict: verdict, onAdd: onAdd))
  }
}

private struct BuffDropModifier: ViewModifier {
  var folderID: Int64
  var verdict: BuffDropVerdict?
  var onAdd: (Buff) -> Void

  @Environment(\.addBuffHost) private var host

  func body(content: Content) -> some View {
    content.onDrop(
      of: [.dirbuffBuff],
      delegate: BuffDropDelegate(folderID: folderID, host: host, verdict: verdict, onAdd: onAdd))
  }
}

private struct BuffDropDelegate: DropDelegate {
  var folderID: Int64
  var host: AddBuffHost
  var verdict: BuffDropVerdict?
  var onAdd: (Buff) -> Void

  func dropEntered(info: DropInfo) {
    host.dropFolderID = folderID
  }

  func dropExited(info: DropInfo) {
    if host.dropFolderID == folderID { host.dropFolderID = nil }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: verdict?.isAdding == true ? .copy : .forbidden)
  }

  func performDrop(info: DropInfo) -> Bool {
    host.dropFolderID = nil
    guard verdict?.isAdding == true, let buff = host.draggedBuff else { return false }
    onAdd(buff)
    return true
  }
}

/// What letting go does, on Accent Blue, or in grey why not.
struct DropCapsule: View {
  var text: String
  var isAccepting: Bool
  var font: Font = .subheadline.weight(.semibold)

  /// The grey of a drop that won't take, the same in light and dark, so white reads on it.
  private static let refusedGrey = Color(red: 0x5A / 255, green: 0x5A / 255, blue: 0x55 / 255)

  var body: some View {
    Text(text)
      .font(font)
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(isAccepting ? Palette.accentBlue : Self.refusedGrey, in: .capsule)
      .shadow(color: .black.opacity(0.28), radius: 5, y: 3)
  }
}
