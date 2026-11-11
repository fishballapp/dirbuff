import Foundation

/// A Drive file's ID. Drive allows duplicate names, so an ID is the only way to name one file.
public struct DriveFileID: Hashable, Sendable, Codable, ExpressibleByStringLiteral,
  CustomStringConvertible
{
  public let rawValue: String

  public init(_ rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { self.init(value) }
  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    self.init(try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A file or folder, as much of it as Backup reads.
public struct DriveItem: Sendable, Equatable, Decodable {
  public static let folderMimeType = "application/vnd.google-apps.folder"

  public var id: DriveFileID
  public var name: String
  public var mimeType: String
  /// Bytes. Folders have none.
  public var size: Int64?
  public var parents: [DriveFileID]
  public var isTrashed: Bool
  public var sha256Checksum: String?
  public var md5Checksum: String?

  public var isFolder: Bool { mimeType == Self.folderMimeType }

  public init(
    id: DriveFileID, name: String, mimeType: String, size: Int64? = nil,
    parents: [DriveFileID] = [], isTrashed: Bool = false, sha256Checksum: String? = nil,
    md5Checksum: String? = nil
  ) {
    self.id = id
    self.name = name
    self.mimeType = mimeType
    self.size = size
    self.parents = parents
    self.isTrashed = isTrashed
    self.sha256Checksum = sha256Checksum
    self.md5Checksum = md5Checksum
  }

  /// The fields every call asks Drive for.
  static let fields = "id,name,mimeType,size,parents,trashed,sha256Checksum,md5Checksum"

  private enum CodingKeys: String, CodingKey {
    case id, name, mimeType, size, parents, trashed, sha256Checksum, md5Checksum
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(DriveFileID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    mimeType = try container.decode(String.self, forKey: .mimeType)
    // Drive writes 64-bit numbers as strings.
    size = try container.decodeIfPresent(String.self, forKey: .size).flatMap { Int64($0) }
    parents = try container.decodeIfPresent([DriveFileID].self, forKey: .parents) ?? []
    isTrashed = try container.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
    sha256Checksum = try container.decodeIfPresent(String.self, forKey: .sha256Checksum)
    md5Checksum = try container.decodeIfPresent(String.self, forKey: .md5Checksum)
  }
}

/// One page of a listing. A nil `nextPageToken` is the last page.
public struct DrivePage: Sendable, Equatable, Decodable {
  public var items: [DriveItem]
  public var nextPageToken: String?

  public init(items: [DriveItem], nextPageToken: String? = nil) {
    self.items = items
    self.nextPageToken = nextPageToken
  }

  private enum CodingKeys: String, CodingKey {
    case items = "files"
    case nextPageToken
  }
}

/// `about.get`: whose Drive this is and how much room it has.
public struct DriveAbout: Sendable, Equatable, Decodable {
  public var email: String
  /// Bytes the account uses across Drive, Gmail and Photos.
  public var usedBytes: Int64
  /// Bytes the account may use; nil when the account has no limit.
  public var limitBytes: Int64?
  /// Google's ID for the account, which stays when its address changes; nil if Google gave none.
  public var permissionID: String?

  /// What tells one account from another: the permission ID, or the address without one.
  public var accountID: String { permissionID ?? email }

  public var freeBytes: Int64? { limitBytes.map { max(0, $0 - usedBytes) } }

  public init(email: String, usedBytes: Int64, limitBytes: Int64?, permissionID: String? = nil) {
    self.email = email
    self.usedBytes = usedBytes
    self.limitBytes = limitBytes
    self.permissionID = permissionID
  }

  static let fields = "user(emailAddress,permissionId),storageQuota(limit,usage)"

  private struct Wire: Decodable {
    struct User: Decodable {
      var emailAddress: String
      var permissionId: String?
    }
    struct Quota: Decodable {
      var limit: String?
      var usage: String?
    }
    var user: User
    var storageQuota: Quota
  }

  public init(from decoder: any Decoder) throws {
    let wire = try Wire(from: decoder)
    email = wire.user.emailAddress
    permissionID = wire.user.permissionId
    usedBytes = wire.storageQuota.usage.flatMap { Int64($0) } ?? 0
    limitBytes = wire.storageQuota.limit.flatMap { Int64($0) }
  }
}
