import AVFoundation
import Foundation
import ImageIO

public struct ResolvedMediaDate: Codable, Equatable, Sendable {
  public enum Source: String, Codable, Sendable { case cloudCapture, imageCapture, originalCreation }
  public let date: Date
  public let source: Source
  public init(date: Date, source: Source) { self.date = date; self.source = source }
}

public enum MediaDateResolver {
  public static func resolve(asset: RemoteAsset, file: URL, timeZone: TimeZone = .current) throws -> ResolvedMediaDate {
    if let date = asset.captureDate { return ResolvedMediaDate(date: date, source: .cloudCapture) }
    if asset.isVideo {
      if let date = AVURLAsset(url: file).creationDate?.dateValue, valid(date) {
        return ResolvedMediaDate(date: date, source: .originalCreation)
      }
    } else if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
      let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
      if let date = exifDate(exif["DateTimeOriginal"] as? String,
        offset: exif["OffsetTimeOriginal"] as? String, timeZone: timeZone) {
        return ResolvedMediaDate(date: date, source: .imageCapture)
      }
      if let date = exifDate(exif["DateTimeDigitized"] as? String,
        offset: exif["OffsetTimeDigitized"] as? String, timeZone: timeZone) {
        return ResolvedMediaDate(date: date, source: .originalCreation)
      }
    }
    throw SyncFailure("缺少有效拍摄时间和原文件创建时间，已保留原文件；不会使用下载时间代替")
  }

  public static func exifDate(_ text: String?, offset: String?, timeZone: TimeZone) -> Date? {
    guard let text, text.range(of: #"^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
    var zone = timeZone
    if let offset {
      guard offset.range(of: #"^[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil,
        let hours = Int(offset.dropFirst().prefix(2)), let minutes = Int(offset.suffix(2)),
        hours <= 14, minutes < 60, hours < 14 || minutes == 0,
        let specified = TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (offset.hasPrefix("-") ? -1 : 1))
      else { return nil }
      zone = specified
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    formatter.isLenient = false
    guard let date = formatter.date(from: text), formatter.string(from: date) == text, valid(date) else { return nil }
    return date
  }
  private static func valid(_ date: Date) -> Bool {
    date.timeIntervalSince1970.isFinite && date.timeIntervalSince1970 > 0 && date.timeIntervalSince1970 < 253_402_300_800
  }
}
