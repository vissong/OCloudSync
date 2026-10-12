import AVFoundation
import Foundation
import ImageIO
import PhotosUI
import SyncCore

func properties(_ url: URL) throws -> [String: Any] {
  guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
  else { throw SyncFailure("Cannot inspect still image") }
  return props
}
func validatePair(still: URL, movie: URL, manifest: LivePhotoManifest) throws {
  let props = try properties(still)
  guard
    (props[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"] as? String
      == manifest.contentIdentifier,
    props[kCGImagePropertyPixelWidth as String] as? Int == manifest.width,
    props[kCGImagePropertyPixelHeight as String] as? Int == manifest.height,
    try RemoteAsset.hashFile(still) == manifest.stillHash,
    try RemoteAsset.hashFile(movie) == manifest.movieHash
  else { throw SyncFailure("Live Photo still/hash validation failed") }
  let asset = AVURLAsset(url: movie)
  guard
    asset.metadata.contains(where: {
      $0.identifier == .quickTimeMetadataContentIdentifier
        && $0.stringValue == manifest.contentIdentifier
    }), !asset.tracks(withMediaType: .video).isEmpty,
    (!asset.tracks(withMediaType: .audio).isEmpty) == manifest.hasAudio,
    abs(asset.duration.seconds - manifest.duration) < 0.15
  else { throw SyncFailure("Live Photo video/identifier/audio/duration validation failed") }
  var marker = false
  for track in asset.tracks(withMediaType: .metadata) {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    guard reader.startReading() else { throw SyncFailure("Metadata reader failed") }
    while let sample = output.copyNextSampleBuffer() {
      if let group = AVTimedMetadataGroup(sampleBuffer: sample) {
        for item in group.items
        where item.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" {
          if abs(group.timeRange.start.seconds - manifest.stillTime) < 0.005 { marker = true }
        }
      }
    }
    guard reader.status == .completed else { throw SyncFailure("Metadata read failed") }
  }
  guard marker else { throw SyncFailure("Missing still-image-time marker") }
  var done = false
  var success = false
  let id = PHLivePhoto.request(
    withResourceFileURLs: [still, movie], placeholderImage: nil,
    targetSize: .zero, contentMode: .aspectFit
  ) { photo, info in
    if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
    success = photo != nil && info[PHLivePhotoInfoErrorKey] == nil
    done = true
  }
  let deadline = Date().addingTimeInterval(30)
  while !done && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
  guard done && success else {
    PHLivePhoto.cancelRequest(withRequestID: id)
    throw SyncFailure("Apple could not construct this Live Photo pair")
  }
}
func convert(input: URL, output: URL, stage: URL) throws {
  let fm = FileManager.default
  let size = (try fm.attributesOfItem(atPath: input.path)[.size] as? NSNumber)?.int64Value ?? 0
  guard size > 0 && size <= 200 * 1024 * 1024 else {
    throw SyncFailure("Motion JPEG exceeds 200 MB limit")
  }
  let hash = try RemoteAsset.hashFile(input)
  let manifestURL = output.appendingPathComponent("manifest.json")
  if let bytes = try? Data(contentsOf: manifestURL),
    let saved = try? JSONDecoder().decode(LivePhotoManifest.self, from: bytes),
    saved.version == 1, saved.sourceHash == hash,
    saved.contentIdentifier == LivePhotoManifest.identifier(sourceHash: hash),
    (try? validatePair(
      still: output.appendingPathComponent("live.heic"),
      movie: output.appendingPathComponent("live.mov"), manifest: saved)) != nil
  {
    return
  }
  guard
    stage.deletingLastPathComponent().standardizedFileURL
      == output.deletingLastPathComponent().standardizedFileURL,
    stage.lastPathComponent.hasPrefix(".converting-"), !fm.fileExists(atPath: stage.path)
  else { throw SyncFailure("Invalid conversion stage") }
  try fm.createDirectory(
    at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? fm.removeItem(at: stage) }
  let data = try Data(contentsOf: input, options: .mappedIfSafe)
  let payload = try MotionJPEG.inspect(data)
  let video = stage.appendingPathComponent("motion.mp4")
  let still = stage.appendingPathComponent("live.heic")
  let movie = stage.appendingPathComponent("live.mov")
  try data.subdata(in: payload.videoOffset..<data.count).write(to: video, options: .atomic)
  let sourceMovie = AVURLAsset(url: video)
  guard let videoTrack = sourceMovie.tracks(withMediaType: .video).first,
    videoTrack.naturalSize.width > 0, videoTrack.naturalSize.height > 0,
    videoTrack.naturalSize.width <= 8192, videoTrack.naturalSize.height <= 8192
  else {
    throw SyncFailure("Invalid or oversized motion video track")
  }
  let time = try MotionJPEG.stillTime(
    microseconds: payload.presentationMicroseconds, duration: sourceMovie.duration.seconds)
  let identifier = LivePhotoManifest.identifier(sourceHash: hash)
  try copyStillHEIC(sourceData: data, offset: payload.videoOffset, uuid: identifier, to: still)
  try makeMOV(
    videoURL: video, outputURL: movie, uuid: identifier,
    stillTime: CMTime(seconds: time.seconds, preferredTimescale: 1_000_000))
  let originalProps = try properties(input)
  let props = try properties(still)
  try StillMetadata.validateGPS(
    originalProps[kCGImagePropertyGPSDictionary as String] as? [String: Any],
    props[kCGImagePropertyGPSDictionary as String] as? [String: Any])
  if let originalEXIF = originalProps[kCGImagePropertyExifDictionary as String] as? [String: Any] {
    let convertedEXIF = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
    for field in [
      kCGImagePropertyExifDateTimeOriginal as String,
      kCGImagePropertyExifDateTimeDigitized as String,
    ] {
      if let value = originalEXIF[field] as? String, convertedEXIF?[field] as? String != value {
        throw SyncFailure("EXIF capture date changed")
      }
    }
  }
  guard
    props[kCGImagePropertyPixelWidth as String] as? Int == originalProps[
      kCGImagePropertyPixelWidth as String] as? Int,
    props[kCGImagePropertyPixelHeight as String] as? Int == originalProps[
      kCGImagePropertyPixelHeight as String] as? Int,
    (props[kCGImagePropertyOrientation as String] as? Int ?? 1)
      == (originalProps[kCGImagePropertyOrientation as String] as? Int ?? 1)
  else { throw SyncFailure("Still dimensions/orientation changed") }
  let manifest = LivePhotoManifest(
    sourceHash: hash, stillHash: try RemoteAsset.hashFile(still),
    movieHash: try RemoteAsset.hashFile(movie),
    width: props[kCGImagePropertyPixelWidth as String] as! Int,
    height: props[kCGImagePropertyPixelHeight as String] as! Int,
    duration: sourceMovie.duration.seconds,
    stillTime: time.seconds, hasAudio: !sourceMovie.tracks(withMediaType: .audio).isEmpty,
    usedFallbackTime: time.usedFallback)
  try validatePair(still: still, movie: movie, manifest: manifest)
  let convertedTrack = AVURLAsset(url: movie).tracks(withMediaType: .video).first!
  guard convertedTrack.preferredTransform == videoTrack.preferredTransform else {
    throw SyncFailure("Video orientation changed")
  }
  try fm.removeItem(at: video)
  try JSONEncoder().encode(manifest).write(
    to: stage.appendingPathComponent("manifest.json"), options: .atomic)
  if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
  try fm.moveItem(at: stage, to: output)
}

umask(0o077)
do {
  guard (3...4).contains(CommandLine.arguments.count) else {
    throw SyncFailure("usage: OCloudLivePhoto source.jpg output-directory [stage-directory]")
  }
  let output = URL(fileURLWithPath: CommandLine.arguments[2])
  try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  let stage =
    CommandLine.arguments.count == 4
    ? URL(fileURLWithPath: CommandLine.arguments[3])
    : output.deletingLastPathComponent().appendingPathComponent(".converting-" + UUID().uuidString)
  try convert(input: URL(fileURLWithPath: CommandLine.arguments[1]), output: output, stage: stage)
} catch {
  fputs("Live Photo conversion failed: \(error.localizedDescription)\n", stderr)
  exit(1)
}
