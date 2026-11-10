import Foundation

/// A snapshot in the repository, as `snapshots` and `forget` list it.
public struct ResticSnapshot: Equatable, Sendable, Decodable {
  public var id: String
  public var shortId: String
  public var time: Date
  public var hostname: String
  public var paths: [String]
  public var tags: [String]

  enum CodingKeys: String, CodingKey {
    case id, shortId, time, hostname, paths, tags
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    shortId = try values.decode(String.self, forKey: .shortId)
    time = try values.decode(Date.self, forKey: .time)
    hostname = try values.decode(String.self, forKey: .hostname)
    paths = try values.decode([String].self, forKey: .paths)
    tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
  }
}

/// The snapshots one `forget` group kept and removed.
public struct ForgetGroup: Equatable, Sendable, Decodable {
  public var host: String
  public var tags: [String]
  public var keep: [ResticSnapshot]
  public var remove: [ResticSnapshot]

  enum CodingKeys: String, CodingKey {
    case host, tags, keep, remove
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    host = try values.decode(String.self, forKey: .host)
    tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
    keep = try values.decodeIfPresent([ResticSnapshot].self, forKey: .keep) ?? []
    remove = try values.decodeIfPresent([ResticSnapshot].self, forKey: .remove) ?? []
  }
}

/// How many snapshots `forget` keeps. Each count keeps the newest snapshot of that many hours,
/// days, weeks, months or years.
public struct ForgetPolicy: Equatable, Sendable {
  public var last: Int?
  public var hourly: Int?
  public var daily: Int?
  public var weekly: Int?
  public var monthly: Int?
  public var yearly: Int?

  public init(
    last: Int? = nil, hourly: Int? = nil, daily: Int? = nil, weekly: Int? = nil,
    monthly: Int? = nil, yearly: Int? = nil
  ) {
    self.last = last
    self.hourly = hourly
    self.daily = daily
    self.weekly = weekly
    self.monthly = monthly
    self.yearly = yearly
  }

  var arguments: [String] {
    [
      ("--keep-last", last), ("--keep-hourly", hourly), ("--keep-daily", daily),
      ("--keep-weekly", weekly), ("--keep-monthly", monthly), ("--keep-yearly", yearly),
    ].flatMap { flag, count in count.map { [flag, String($0)] } ?? [] }
  }
}
