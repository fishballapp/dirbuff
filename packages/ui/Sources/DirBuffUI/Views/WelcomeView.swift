import SwiftUI

/// The first-run window: the app, one sentence, the buffs as pieces to drop on four folder tiles,
/// the setup checklist and the trial. **Set Up…** in Settings opens it again. It sits under a
/// title bar the window draws transparent, so the top margin is short.
public struct WelcomeView: View {
  public var state: WelcomeState
  public var appIcon: Image
  public var onChoose: (WelcomeFolder) -> Void
  public var onChooseOther: () -> Void
  public var onUndo: (WelcomePlacement) -> Void
  public var onChange: (WelcomePlacement) -> Void
  public var onOpenExtensionManagement: () -> Void
  public var onToggleOpenAtLogin: (Bool) -> Void
  public var onOpenLoginItemsSettings: () -> Void
  public var onRequestNotifications: () -> Void
  public var onEnterKey: () -> Void
  public var onClose: () -> Void

  @State private var targeted: String?

  public init(
    state: WelcomeState,
    appIcon: Image,
    onChoose: @escaping (WelcomeFolder) -> Void = { _ in },
    onChooseOther: @escaping () -> Void = {},
    onUndo: @escaping (WelcomePlacement) -> Void = { _ in },
    onChange: @escaping (WelcomePlacement) -> Void = { _ in },
    onOpenExtensionManagement: @escaping () -> Void = {},
    onToggleOpenAtLogin: @escaping (Bool) -> Void = { _ in },
    onOpenLoginItemsSettings: @escaping () -> Void = {},
    onRequestNotifications: @escaping () -> Void = {},
    onEnterKey: @escaping () -> Void = {},
    onClose: @escaping () -> Void = {}
  ) {
    self.state = state
    self.appIcon = appIcon
    self.onChoose = onChoose
    self.onChooseOther = onChooseOther
    self.onUndo = onUndo
    self.onChange = onChange
    self.onOpenExtensionManagement = onOpenExtensionManagement
    self.onToggleOpenAtLogin = onToggleOpenAtLogin
    self.onOpenLoginItemsSettings = onOpenLoginItemsSettings
    self.onRequestNotifications = onRequestNotifications
    self.onEnterKey = onEnterKey
    self.onClose = onClose
  }

  public var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        header
        pieces.padding(.top, 18)
        tiles.padding(.top, 20)
        message.padding(.top, 8)
      }
      .padding(.top, 14)
      .padding(.horizontal, 36)
      .padding(.bottom, 24)

      checklist
      foot
    }
    .frame(width: 700)
    .background(Palette.paper)
  }

  // MARK: - Header

  private var header: some View {
    VStack(spacing: 0) {
      appIcon
        .resizable()
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
      Text("Welcome to DirBuff")
        .font(.title.bold())
        .padding(.top, 14)
      Text("Give a folder a buff to do a job automatically.")
        .foregroundStyle(Palette.inkSecondary)
        .padding(.top, 4)
    }
  }

  // MARK: - Buff pieces

  private var pieces: some View {
    HStack(spacing: 10) {
      ForEach(Buff.allCases, id: \.self) { buff in
        BuffPiece(buff).fixedSize()
      }
    }
  }

  // MARK: - Folder tiles

  private var tiles: some View {
    HStack(spacing: 10) {
      ForEach(state.folders) { folder in
        FolderDropTile(
          folder: folder, placement: state.placement(on: folder),
          isTargeted: targetBinding(folder.id), onChoose: { onChoose(folder) })
      }
      if let other = state.otherFolder, let placement = state.otherPlacement {
        FolderDropTile(
          folder: other, placement: placement,
          isTargeted: targetBinding(other.id), onChoose: onChooseOther)
      } else {
        OtherFolderTile(isTargeted: targetBinding("other"), onChoose: onChooseOther)
      }
    }
  }

  private func targetBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { targeted == id }, set: { targeted = $0 ? id : (targeted == id ? nil : targeted) })
  }

  // MARK: - What just happened

  @ViewBuilder
  private var message: some View {
    if let refusal = state.refusal {
      Text(refusal)
        .foregroundStyle(Palette.inkSecondary)
        .frame(minHeight: 19)
    } else if let placement = state.chosenPlacement {
      VStack(spacing: 4) {
        HStack(spacing: 6) {
          Text("Temporary is on").fontWeight(.semibold)
          FolderPill(placement.folder.name, path: placement.folder.path)
        }
        Text(placement.sentence)
          .foregroundStyle(Palette.inkSecondary)
        HStack(spacing: 6) {
          if state.canUndo(placement) {
            Button("Undo") { onUndo(placement) }
          }
          Button("Change…") { onChange(placement) }
        }
        .controlSize(.small)
        .padding(.top, 4)
      }
    } else {
      Text("Drag a buff onto a folder, here or in Finder.")
        .foregroundStyle(Palette.inkSecondary)
        .frame(minHeight: 19)
    }
  }

  // MARK: - Checklist

  private var checklist: some View {
    VStack(spacing: 0) {
      SetupRow(title: "Finder extension", isDone: state.setup.isExtensionEnabled) {
        Button("Turn On…", action: onOpenExtensionManagement)
      }
      if !state.setup.isExtensionEnabled {
        Text("System Settings › General › Login Items & Extensions")
          .font(.subheadline)
          .foregroundStyle(Palette.inkTertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, 26)
          .padding(.bottom, 4)
      }
      SetupRow(title: "Open at login", isDone: state.setup.isOpenAtLogin) {
        if state.setup.isOpenAtLoginRequiresApproval {
          Button("Turn On…", action: onOpenLoginItemsSettings)
        } else {
          Button("Turn On") { onToggleOpenAtLogin(true) }
        }
      }
      SetupRow(title: "Notifications", isDone: state.setup.isNotificationsEnabled) {
        Button("Turn On", action: onRequestNotifications)
      }
    }
    .padding(.horizontal, 36)
    .padding(.top, 8)
    .padding(.bottom, 10)
    .overlay(alignment: .top) {
      Rectangle().fill(Palette.rule).frame(height: 1).padding(.horizontal, 36)
    }
  }

  // MARK: - Foot

  private var foot: some View {
    HStack {
      Text(state.licence.welcomeLine)
        .font(.callout)
        .foregroundStyle(Palette.inkTertiary)
      Spacer()
      if !state.licence.hasKey {
        Button("Enter Licence Key…", action: onEnterKey)
      }
      Button(state.closeTitle, action: onClose)
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .background(Palette.well)
  }
}

// MARK: - Tiles

private let tileSize = CGSize(width: 124, height: 138)

/// The dashed tile a piece is dropped on, or clicked: a folder, and once Temporary is on it, the
/// mark and the setting.
private struct FolderDropTile: View {
  let folder: WelcomeFolder
  let placement: WelcomePlacement?
  @Binding var isTargeted: Bool
  let onChoose: () -> Void

  var body: some View {
    DropTileFrame(isDone: placement != nil, isTargeted: isTargeted, onChoose: onChoose) {
      VStack(spacing: 8) {
        MarkedFolderIcon(path: folder.path, mark: placement == nil ? nil : .atRest)
        Text(folder.name)
          .font(.system(size: 12, weight: .medium))
          .lineLimit(1)
        if let placement {
          HStack(spacing: 4) {
            BuffSymbol(.temporary, width: 14)
            Text(placement.setting)
          }
          .font(.subheadline)
          .foregroundStyle(Palette.inkSecondary)
        }
      }
    }
    .modifier(TemporaryDrop(isTargeted: $isTargeted, onDrop: onChoose))
    .accessibilityLabel(
      placement.map { "\(folder.name), Temporary, \($0.setting)" } ?? folder.name
    )
    .accessibilityHint("Puts Temporary on \(folder.name)")
  }
}

/// "Other Folder…": asks which folder, for a click or a dropped piece.
private struct OtherFolderTile: View {
  @Binding var isTargeted: Bool
  let onChoose: () -> Void

  var body: some View {
    DropTileFrame(isDone: false, isTargeted: isTargeted, onChoose: onChoose) {
      VStack(spacing: 8) {
        Image(systemName: "plus")
          .font(.system(size: 14, weight: .regular))
          .foregroundStyle(Palette.inkSecondary)
          .frame(width: 44, height: 44)
          .background(Color.primary.opacity(0.05), in: .circle)
        Text("Other Folder…")
          .font(.system(size: 12, weight: .medium))
      }
    }
    .modifier(TemporaryDrop(isTargeted: $isTargeted, onDrop: onChoose))
    .accessibilityHint("Choose a folder to put Temporary on")
  }
}

/// Takes a Temporary piece dropped on a tile, from here or the main window's Buffs page.
private struct TemporaryDrop: ViewModifier {
  @Binding var isTargeted: Bool
  let onDrop: () -> Void

  @Environment(\.addBuffHost) private var host

  func body(content: Content) -> some View {
    content.onDrop(of: [.dirbuffBuff], isTargeted: $isTargeted) { _ in
      guard host.draggedBuff == .temporary else { return false }
      onDrop()
      return true
    }
  }
}

/// A tile's frame: dashed until a buff is on it, then Blue Tint inside an Accent Blue edge; a
/// drop target under a piece takes the tint and a heavier ring.
private struct DropTileFrame<Content: View>: View {
  let isDone: Bool
  let isTargeted: Bool
  let onChoose: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    Button(action: onChoose) {
      content
        .frame(width: tileSize.width, height: tileSize.height)
        .background(
          isDone || isTargeted ? Palette.blueTint : .clear,
          in: .rect(cornerRadius: Metrics.tileRadius)
        )
        .overlay {
          if isDone || isTargeted {
            RoundedRectangle(cornerRadius: Metrics.tileRadius)
              .stroke(Palette.accentBlue, lineWidth: isTargeted ? 1.5 : 1)
          } else {
            RoundedRectangle(cornerRadius: Metrics.tileRadius)
              .strokeBorder(Palette.ruleStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
          }
        }
        .contentShape(.rect(cornerRadius: Metrics.tileRadius))
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Checklist

/// One row of the setup checklist: its real state, then what to do about it.
private struct SetupRow<Action: View>: View {
  let title: String
  let isDone: Bool
  @ViewBuilder let action: Action

  var body: some View {
    HStack(spacing: 10) {
      Group {
        if isDone {
          Canvas { context, size in
            let unit = size.width / 16
            context.fill(
              Path(ellipseIn: CGRect(x: unit, y: unit, width: 14 * unit, height: 14 * unit)),
              with: .color(doneGreen))
            var check = Path()
            check.move(to: CGPoint(x: 4.8 * unit, y: 8.2 * unit))
            check.addLine(to: CGPoint(x: 6.9 * unit, y: 10.3 * unit))
            check.addLine(to: CGPoint(x: 11.2 * unit, y: 5.7 * unit))
            context.stroke(
              check, with: .color(.white),
              style: StrokeStyle(lineWidth: 1.7 * unit, lineCap: .round, lineJoin: .round))
          }
        } else {
          Circle().strokeBorder(Palette.inkTertiary, lineWidth: 1.4).padding(1)
        }
      }
      .frame(width: 16, height: 16)
      .accessibilityLabel(isDone ? "Done" : "Not done")

      Text(title)
        .font(.system(size: 12.5, weight: .medium))
      Spacer()
      if isDone {
        Text("On")
          .font(.system(size: 12))
          .foregroundStyle(Palette.inkTertiary)
      } else {
        action
      }
    }
    .frame(minHeight: 30)
  }
}

/// The checklist's one green, set in the design reference; it appears nowhere else.
private let doneGreen = Color(red: 0x2E / 255, green: 0x9E / 255, blue: 0x5B / 255)
