import SwiftUI

/// What goes next from a folder, pushed from its page's What Goes Next…. A stub until the files
/// page is built.
public struct FolderFilesPage: View {
  public var folder: MainFolder

  public init(folder: MainFolder) {
    self.folder = folder
  }

  public var body: some View {
    ScrollView { ForecastList(groups: folder.preview.forecast).padding(32) }
      .background(Palette.paper)
      .navigationTitle(folder.name)
  }
}
