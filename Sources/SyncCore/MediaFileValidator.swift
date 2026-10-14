import AVFoundation
import Foundation
import ImageIO

public struct VideoPlaybackUnsupported: LocalizedError {
  public var errorDescription: String? { "macOS 无法播放此视频编码或封装；保留原文件等待兼容处理" }
}

/// Reads local originals on a worker task; it never transcodes or opens a Photos library.
public enum MediaFileValidator {
  public static func validate(_ file: URL, asset: RemoteAsset) async throws -> String {
    try Task.checkCancellation()
    let worker = Task.detached(priority: .utility) { try await inspect(file, asset: asset) }
    return try await withTaskCancellationHandler(operation: {
      let hash = try await worker.value
      try Task.checkCancellation()
      return hash
    }, onCancel: { worker.cancel() })
  }
  private static func inspect(_ file: URL, asset: RemoteAsset) async throws -> String {
    try Task.checkCancellation()
    guard asset.supported else { throw SyncFailure("此文件类型暂不支持") }
    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
    guard size == asset.bytes else { throw SyncFailure("下载文件大小与云端不一致，将重新下载") }
    if asset.isVideo {
      let movie = AVURLAsset(url: file)
      let playable = try await movie.load(.isPlayable)
      let duration = try await movie.load(.duration).seconds
      let tracks = try await movie.loadTracks(withMediaType: .video)
      guard duration.isFinite, duration > 0, let track = tracks.first else {
        throw SyncFailure("视频格式、轨道或时长校验未通过；保留原文件等待重试")
      }
      let raw = try await track.load(.naturalSize)
      let transform = try await track.load(.preferredTransform)
      let display = raw.applying(transform)
      func matches(_ size: CGSize) -> Bool {
        abs(abs(size.width) - Double(asset.width)) < 1 && abs(abs(size.height) - Double(asset.height)) < 1
      }
      guard asset.width > 0, asset.height > 0, raw.width > 0, raw.height > 0,
        matches(raw) || matches(display)
      else { throw SyncFailure("视频尺寸与云端不一致；保留原文件等待重试") }
      guard playable else { throw VideoPlaybackUnsupported() }
    } else {
      guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
        asset.isMotionJPEG ? CGImageSourceGetCount(source) >= 1 : CGImageSourceGetCount(source) == 1,
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width == asset.width, height == asset.height
      else { throw SyncFailure("原图格式或像素校验未通过，将保留错误状态") }
    }
    try Task.checkCancellation()
    return try RemoteAsset.hashFile(file)
  }
}
