import DirBuffCore
import DirBuffKit
import Foundation

/// The files the last backup of a folder couldn't read, each with why, and **Leave Out** for each:
/// what **Show Files…** opens. Leaving a file out adds its path
/// to the folder's leave-outs (`BackupBuff.leaveOut`), so it stops being counted and the folder's
/// row clears. The model only; the view is Backup's page when the buff goes live.
public struct UnreadFilesState: Sendable, Equatable {
  public var folderID: Int64
  public var folderName: String
  /// "3 files couldn't be backed up".
  public var title: String
  public var files: [UnreadFile]

  /// Nil when the folder wears no Backup, or the last backup read every file.
  public init?(_ report: FolderReport) {
    guard let id = report.folder.id, let status = report.backupStatus, !status.skipped.isEmpty
    else { return nil }
    folderID = id
    folderName = report.name
    title = filesCouldNotBeBackedUp(status.skipped.count)
    files = status.skipped.map(UnreadFile.init)
  }
}

public struct UnreadFile: Sendable, Equatable, Identifiable {
  /// Inside the folder.
  public var path: String
  public var name: String
  /// The folders it is in, inside the backed-up folder; empty at its top.
  public var parent: String
  /// Why it couldn't be read, in words: "DirBuff may not read it".
  public var reason: String

  public var id: String { path }

  /// What **Leave Out** passes to `BackupBuff.leaveOut`.
  public var leaveOut: LeaveOut { .path(path) }

  init(_ file: SkippedFile) {
    path = file.path
    let parts = file.path.split(separator: "/")
    name = parts.last.map(String.init) ?? file.path
    parent = parts.dropLast().joined(separator: "/")
    reason = unreadReason(file.reason)
  }
}

/// restic's message for a file it couldn't read ("open /x/secret: permission denied") in words.
func unreadReason(_ message: String) -> String {
  let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
  let cause = (line.split(separator: ":").last.map(String.init) ?? line)
    .trimmingCharacters(in: .whitespaces)
    .lowercased()
  switch cause {
  case "permission denied", "operation not permitted": return "DirBuff may not read it"
  case "resource busy", "text file busy", "resource temporarily unavailable":
    return "Another app has it open"
  case "": return "It couldn't be read"
  default: return cause.prefix(1).uppercased() + cause.dropFirst()
  }
}
