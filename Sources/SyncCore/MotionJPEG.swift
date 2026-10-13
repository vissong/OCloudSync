import Foundation

public struct LivePhotoManifest: Codable, Equatable, Sendable {
  public let version: Int
  public let sourceHash: String
  public let contentIdentifier: String
  public let stillHash: String, movieHash: String
  public let width: Int, height: Int
  public let duration: Double, stillTime: Double
  public let hasAudio: Bool, usedFallbackTime: Bool
  public init(
    sourceHash: String, stillHash: String, movieHash: String, width: Int, height: Int,
    duration: Double, stillTime: Double, hasAudio: Bool, usedFallbackTime: Bool
  ) {
    version = 1
    self.sourceHash = sourceHash
    contentIdentifier = Self.identifier(sourceHash: sourceHash)
    self.stillHash = stillHash
    self.movieHash = movieHash
    self.width = width
    self.height = height
    self.duration = duration
    self.stillTime = stillTime
    self.hasAudio = hasAudio
    self.usedFallbackTime = usedFallbackTime
  }
  public static func identifier(sourceHash: String) -> String {
    let h = Array(
      RemoteAsset.digest(Data(("OCloudSync.LivePhoto.v1:" + sourceHash).utf8)).prefix(32))
    return [
      String(h[0..<8]), String(h[8..<12]), "5" + String(h[13..<16]),
      "a" + String(h[17..<20]), String(h[20..<32]),
    ].joined(separator: "-").uppercased()
  }
}

public enum MotionJPEG {
  public struct Payload {
    public let videoOffset: Int
    public let presentationMicroseconds: Int64?
  }
  public static func presentationTimestamp(in data: Data) throws -> Int64? {
    let text = String(decoding: data, as: UTF8.self)
    let field = "(?:MotionPhoto|MicroVideo)PresentationTimestampUs"
    let regex = try NSRegularExpression(pattern: field + #"\s*=\s*(["'])([^"']*)\1"#)
    let range = NSRange(text.startIndex..., in: text)
    let fieldCount = try NSRegularExpression(pattern: field).numberOfMatches(in: text, range: range)
    let matches = regex.matches(in: text, range: range)
    guard matches.count == fieldCount else { throw SyncFailure("实况封面时间标记无效或互相冲突") }
    let values = try matches.map { match -> Int64 in
      guard let r = Range(match.range(at: 2), in: text), let value = Int64(text[r]) else {
        throw SyncFailure("实况封面时间标记无效或互相冲突")
      }
      return value
    }
    if let first = values.first {
      guard values.allSatisfy({ $0 == first }), first >= -1 else {
        throw SyncFailure("实况封面时间标记无效或互相冲突")
      }
      return first
    }
    return nil
  }
  public static func stillTime(microseconds: Int64?, duration: Double) throws -> (
    seconds: Double, usedFallback: Bool
  ) {
    guard duration.isFinite, duration > 0, duration <= 60 else {
      throw SyncFailure("实况视频时长无效或超过 60 秒")
    }
    let explicit = microseconds.flatMap { $0 >= 0 ? Double($0) / 1_000_000 : nil }
    let seconds = explicit ?? duration / 2
    guard seconds >= 0, seconds < duration else { throw SyncFailure("实况封面时间超出视频范围") }
    return (seconds, explicit == nil)
  }
  public static func inspect(_ data: Data) throws -> Payload {
    guard data.count <= 200 * 1024 * 1024, data.starts(with: [0xff, 0xd8]) else {
      throw SyncFailure("目前仅支持 200 MB 以内、JPEG 尾部内嵌 MP4 的 OPPO 实况")
    }
    let needle = Data("ftypmp42".utf8)
    var cursor = 0
    var candidates = [Int]()
    while cursor < data.count, let range = data.range(of: needle, in: cursor..<data.count) {
      let offset = range.lowerBound - 4
      if offset >= 4, data.prefix(offset).range(of: Data([0xff, 0xd9])) != nil,
        validMP4(data, from: offset)
      {
        candidates.append(offset)
      }
      cursor = range.upperBound
    }
    guard candidates.count == 1, let offset = candidates.first else {
      throw SyncFailure("未找到唯一完整的实况 MP4 视频")
    }
    return Payload(
      videoOffset: offset,
      presentationMicroseconds: try presentationTimestamp(in: data.prefix(offset)))
  }
  private static func validMP4(_ data: Data, from start: Int) -> Bool {
    var p = start
    var types = Set<String>()
    func number(_ range: Range<Int>) -> UInt64 { range.reduce(0) { ($0 << 8) | UInt64(data[$1]) } }
    while p + 8 <= data.count {
      let size = number(p..<p + 4)
      let type = String(decoding: data[p + 4..<p + 8], as: UTF8.self)
      let header = size == 1 ? 16 : 8
      guard p + header <= data.count else { return false }
      let length = size == 1 ? number(p + 8..<p + 16) : size == 0 ? UInt64(data.count - p) : size
      guard length >= UInt64(header), length <= UInt64(data.count - p) else { return false }
      types.insert(type)
      p += Int(length)
    }
    return p == data.count && types.isSuperset(of: ["ftyp", "moov", "mdat"])
  }
}
