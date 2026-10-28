import SwiftUI

/// History's list of runs, newest first; with a folder, only that folder's. A stub until History is
/// built.
public struct HistoryPage: View {
  public var folderID: Int64?

  public init(folderID: Int64?) {
    self.folderID = folderID
  }

  public var body: some View {
    Text("No runs yet")
      .foregroundStyle(Palette.inkSecondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.paper)
      .navigationTitle("History")
  }
}
