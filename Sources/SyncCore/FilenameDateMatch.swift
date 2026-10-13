import Foundation

public enum FilenameDateMatch {
  public static func matches(asset: RemoteAsset, date: Date, filename: String, creationDate: Date?,
    isVideo: Bool, isLivePhoto: Bool) -> Bool {
    guard let creationDate, asset.isVideo == isVideo,
      date.timeIntervalSince1970.isFinite, creationDate.timeIntervalSince1970.isFinite,
      floor(date.timeIntervalSince1970) == floor(creationDate.timeIntervalSince1970) else { return false }
    let original = (asset.filename as NSString).lastPathComponent
    var names = [original]
    if asset.isMotionJPEG && isLivePhoto {
      names.append((original as NSString).deletingPathExtension + ".heic")
    }
    return names.contains { $0.precomposedStringWithCanonicalMapping.caseInsensitiveCompare(
      filename.precomposedStringWithCanonicalMapping) == .orderedSame }
  }
}
