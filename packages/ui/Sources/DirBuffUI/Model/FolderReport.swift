import DirBuffKit
import Foundation

/// A folder and its status; no status when the folder couldn't be read (on a drive that's
/// unplugged, permissions changed).
public struct FolderReport: Sendable {
  public var folder: Folder
  public var status: Engine.FolderStatus?

  public init(folder: Folder, status: Engine.FolderStatus?) {
    self.folder = folder
    self.status = status
  }

  var name: String { URL(fileURLWithPath: folder.path).lastPathComponent }
}
