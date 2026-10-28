import SwiftUI

/// One run's page: what it removed, by folder, with Put Back. A stub until History is built.
public struct RunPage: View {
  public var runID: Int64

  public init(runID: Int64) {
    self.runID = runID
  }

  public var body: some View {
    Text("Run \(runID)")
      .foregroundStyle(Palette.inkSecondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
  }
}
