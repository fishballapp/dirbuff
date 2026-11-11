import Foundation

/// A snapshot in the repository, as `snapshots` and `forget` list it.
public struct ResticSnapshot: Equatable, Sendable, Decodable {
  public var id: String
  public var shortId: String
  public var time: Date
  public var hostname: String
  public var paths: [String]
  public var tags: [String]
  /// The bytes of the files it holds, which a restore writes; nil from a restic before 0.17.
  public var size: Int64?

  enum CodingKeys: String, CodingKey {
    case id, shortId, time, hostname, paths, tags, summary
  }

  private struct Summary: Decodable {
    var totalBytesProcessed: Int64
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    shortId = try values.decode(String.self, forKey: .shortId)
    time = try values.decode(Date.self, forKey: .time)
    hostname = try values.decode(String.self, forKey: .hostname)
    paths = try values.decode([String].self, forKey: .paths)
    tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
    size = try values.decodeIfPresent(Summary.self, forKey: .summary)?.totalBytesProcessed
  }
}

/// A file or folder in a snapshot, as `tree` lists a folder's.
public struct TreeNode: Equatable, Sendable, Decodable {
  public var name: String
  /// `file`, `dir`, `symlink` and the other kinds restic saves.
  public var type: String
  public var size: Int64?
  /// A file's blobs, in order, each named by the SHA-256 of its bytes.
  public var content: [String]?

  public var isFile: Bool { type == "file" }
  public var isFolder: Bool { type == "dir" }
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

/// Which snapshots `forget` keeps. A count keeps the newest snapshot of each of that many hours,
/// days, weeks, months or years that have one; a `within` span keeps the newest of each hour, day,
/// week, month or year that falls within that span of the newest snapshot, however many have none.
public struct ForgetPolicy: Equatable, Sendable {
  public var last: Count?
  public var hourly: Count?
  public var daily: Count?
  public var weekly: Count?
  public var monthly: Count?
  public var yearly: Count?
  public var withinHourly: Span?
  public var withinDaily: Span?
  public var withinWeekly: Span?
  public var withinMonthly: Span?
  public var withinYearly: Span?

  public init(
    last: Count? = nil, hourly: Count? = nil, daily: Count? = nil, weekly: Count? = nil,
    monthly: Count? = nil, yearly: Count? = nil, withinHourly: Span? = nil,
    withinDaily: Span? = nil, withinWeekly: Span? = nil, withinMonthly: Span? = nil,
    withinYearly: Span? = nil
  ) {
    self.last = last
    self.hourly = hourly
    self.daily = daily
    self.weekly = weekly
    self.monthly = monthly
    self.yearly = yearly
    self.withinHourly = withinHourly
    self.withinDaily = withinDaily
    self.withinWeekly = withinWeekly
    self.withinMonthly = withinMonthly
    self.withinYearly = withinYearly
  }

  public enum Count: Equatable, Sendable, ExpressibleByIntegerLiteral {
    case of(Int)
    case unlimited

    public init(integerLiteral value: Int) { self = .of(value) }

    var argument: String {
      switch self {
      case .of(let count): String(count)
      case .unlimited: "unlimited"
      }
    }
  }

  /// A span of calendar time, as restic writes it: `2y5m7d3h`.
  public struct Span: Equatable, Sendable {
    public var years = 0
    public var months = 0
    public var days = 0
    public var hours = 0

    public static func years(_ years: Int) -> Span { Span(years: years) }
    public static func months(_ months: Int) -> Span { Span(months: months) }
    public static func days(_ days: Int) -> Span { Span(days: days) }
    public static func hours(_ hours: Int) -> Span { Span(hours: hours) }

    var argument: String {
      [(years, "y"), (months, "m"), (days, "d"), (hours, "h")]
        .filter { count, _ in count != 0 }
        .map { count, unit in "\(count)\(unit)" }
        .joined()
    }
  }

  var arguments: [String] {
    let counts: [(String, Count?)] = [
      ("--keep-last", last), ("--keep-hourly", hourly), ("--keep-daily", daily),
      ("--keep-weekly", weekly), ("--keep-monthly", monthly), ("--keep-yearly", yearly),
    ]
    let spans: [(String, Span?)] = [
      ("--keep-within-hourly", withinHourly), ("--keep-within-daily", withinDaily),
      ("--keep-within-weekly", withinWeekly), ("--keep-within-monthly", withinMonthly),
      ("--keep-within-yearly", withinYearly),
    ]
    return counts.flatMap { flag, count in count.map { [flag, $0.argument] } ?? [] }
      + spans.flatMap { flag, span in span.map { [flag, $0.argument] } ?? [] }
  }
}

/// A key that opens the repository.
public struct ResticKey: Equatable, Sendable, Decodable {
  public var id: String
  /// Whether it's the key the command opened the repository with.
  public var isCurrent: Bool

  enum CodingKeys: String, CodingKey {
    case id
    case isCurrent = "current"
  }
}
