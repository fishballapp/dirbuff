import AppKit

/// A folder's Finder icon, or the generic folder icon when the folder has moved or been deleted.
func folderIcon(atPath path: String) -> NSImage {
  FileManager.default.fileExists(atPath: path)
    ? NSWorkspace.shared.icon(forFile: path)
    : NSWorkspace.shared.icon(for: .folder)
}
