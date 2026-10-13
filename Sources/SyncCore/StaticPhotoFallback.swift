import Foundation
import ImageIO

public struct StaticFallbackInfo: Codable, Equatable, Sendable {
  public let sourceHash: String
  public let stillHash: String
  public let reason: String
  public init(sourceHash: String, stillHash: String, reason: String) {
    self.sourceHash = sourceHash; self.stillHash = stillHash; self.reason = String(reason.prefix(400))
  }
}
public struct PreparedStaticPhoto: Sendable {
  public let file: URL
  public let asset: RemoteAsset
  public let info: StaticFallbackInfo
}
public enum StaticPhotoFallback {
  public static func prepare(_ original: URL, asset: RemoteAsset, sourceHash: String, reason: String) async throws -> PreparedStaticPhoto {
    try Task.checkCancellation()
    let worker = Task.detached(priority: .utility) {
      try prepareFile(original,asset: asset,sourceHash: sourceHash,reason: reason)
    }
    return try await withTaskCancellationHandler(operation: {
      let result = try await worker.value
      try Task.checkCancellation()
      return result
    },onCancel: { worker.cancel() })
  }
  private static func prepareFile(_ original: URL, asset: RemoteAsset, sourceHash: String, reason: String) throws -> PreparedStaticPhoto {
    try Task.checkCancellation()
    guard asset.isMotionJPEG, try RemoteAsset.hashFile(original) == sourceHash else {
      throw SyncFailure("静态回退的原文件校验未通过")
    }
    let data = try Data(contentsOf: original,options: .mappedIfSafe)
    let still = data.prefix(try jpegEnd(in: data))
    guard let source = CGImageSourceCreateWithData(still as CFData,nil),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
      properties[kCGImagePropertyPixelWidth] as? Int == asset.width,
      properties[kCGImagePropertyPixelHeight] as? Int == asset.height,
      CGImageSourceCreateImageAtIndex(source,0,nil) != nil,
      CGImageSourceGetStatusAtIndex(source,0) == .statusComplete
    else { throw SyncFailure("实况静态主图不完整，保留原文件等待重试") }
    let hash = RemoteAsset.digest(still)
    let directory = original.deletingLastPathComponent().appendingPathComponent("staticphotos").appendingPathComponent(sourceHash)
    try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let file = directory.appendingPathComponent("original.jpg")
    try Task.checkCancellation()
    if (try? RemoteAsset.hashFile(file)) != hash {
      try still.write(to: file,options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath: file.path)
    }
    var staticAsset = asset; staticAsset.isMotion = false; staticAsset.bytes = Int64(still.count)
    return PreparedStaticPhoto(file: file,asset: staticAsset,
      info: StaticFallbackInfo(sourceHash: sourceHash,stillHash: hash,reason: reason))
  }
  /// Parse JPEG segments and entropy markers. Embedded EXIF thumbnails can contain their own EOI.
  public static func jpegEnd(in data: Data) throws -> Int {
    guard data.starts(with: [0xff,0xd8]) else { throw SyncFailure("静态主图不是 JPEG") }
    var cursor = 2, inScan = false
    while cursor < data.count {
      try Task.checkCancellation()
      if inScan {
        while cursor < data.count && data[cursor] != 0xff { cursor += 1 }
      }
      guard cursor < data.count, data[cursor] == 0xff else { break }
      while cursor < data.count && data[cursor] == 0xff { cursor += 1 }
      guard cursor < data.count else { break }
      let marker = data[cursor]; cursor += 1
      if inScan && (marker == 0 || (0xd0...0xd7).contains(marker)) { continue }
      if marker == 0xd9 { return cursor }
      if marker == 0x01 { continue }
      guard marker != 0xd8, marker != 0, cursor + 2 <= data.count else { break }
      let size = Int(data[cursor]) * 256 + Int(data[cursor+1])
      guard size >= 2, size <= data.count - cursor else { break }
      cursor += size
      inScan = marker == 0xda
    }
    throw SyncFailure("JPEG 静态主图已截断，不能回退导入")
  }
}
