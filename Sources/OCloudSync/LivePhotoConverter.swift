import Foundation
import SyncCore

struct PreparedLivePhoto {
  let directory: URL
  let manifest: LivePhotoManifest
  var still: URL { directory.appendingPathComponent("live.heic") }
  var movie: URL { directory.appendingPathComponent("live.mov") }
}

@MainActor
enum LivePhotoConverter {
  static func prepare(_ original: URL, asset: RemoteAsset, hash: String) async throws
    -> PreparedLivePhoto
  {
    guard asset.isMotionJPEG else { throw SyncFailure("目前仅支持 JPEG 内嵌视频的 OPPO 实况") }
    let root = original.deletingLastPathComponent().appendingPathComponent(
      "livephotos", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let directory = root.appendingPathComponent(hash, isDirectory: true)
    let errorURL = root.appendingPathComponent(".worker-" + UUID().uuidString + ".log")
    FileManager.default.createFile(
      atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let errors = try FileHandle(forWritingTo: errorURL)
    defer {
      try? errors.close()
      try? FileManager.default.removeItem(at: errorURL)
    }
    let process = Process()
    process.executableURL = Bundle.main.executableURL?.deletingLastPathComponent()
      .appendingPathComponent("OCloudLivePhoto")
    let stage = root.appendingPathComponent(".converting-" + UUID().uuidString)
    process.arguments = [original.path, directory.path, stage.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try await ConversionWorker.run(process, stage: stage)
    guard process.terminationStatus == 0 else {
      let message =
        (try? String(contentsOf: errorURL))?.split(separator: "\n").last.map(String.init) ?? "转换失败"
      throw SyncFailure("实况转换失败：" + String(message.prefix(400)))
    }
    let manifest = try JSONDecoder().decode(
      LivePhotoManifest.self,
      from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    let pair = PreparedLivePhoto(directory: directory, manifest: manifest)
    guard manifest.version == 1, manifest.sourceHash == hash,
      manifest.contentIdentifier == LivePhotoManifest.identifier(sourceHash: hash),
      manifest.width == asset.width, manifest.height == asset.height,
      try RemoteAsset.hashFile(pair.still) == manifest.stillHash,
      try RemoteAsset.hashFile(pair.movie) == manifest.movieHash
    else { throw SyncFailure("实况转换结果与原图不匹配，未导入") }
    return pair
  }
}
