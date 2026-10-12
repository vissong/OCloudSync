import CryptoKit
import Foundation
import ImageIO
import Photos
import SyncCore

struct ConfirmedImportFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String = "系统明确拒绝了 Live Photo 导入，已保留原图与配对资源，将稍后重试") { errorDescription = message }
}

final class PhotoImporter {
  struct Receipt: Codable {
    let photoID: String
    var livePhoto: LivePhotoManifest?
  }
  let journalDirectory: URL
  init(directory: URL) throws {
    journalDirectory = directory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }
  func authorize() async throws {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    guard status == .authorized else { throw SyncFailure("需要完整照片图库权限才能查重并导入；请在系统设置中允许") }
  }
  func checkPermission() throws {
    guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
      throw SyncFailure("请先授权照片图库访问")
    }
  }
  private func lookupOptions() -> PHFetchOptions {
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    options.includeAllBurstAssets = true
    return options
  }
  func exists(_ id: String) -> Bool {
    PHAsset.fetchAssets(withLocalIdentifiers: [id], options: lookupOptions()).count == 1
  }
  func receipt(for key: String) throws -> Receipt? {
    let url = journalDirectory.appendingPathComponent(key + ".json")
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
  }
  func validate(_ file: URL, asset: RemoteAsset) throws -> String {
    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
      .int64Value
    guard size == asset.bytes else { throw SyncFailure("下载文件大小与云端不一致，将重新下载") }
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
      asset.isMotionJPEG ? CGImageSourceGetCount(source) >= 1 : CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width == asset.width, height == asset.height
    else { throw SyncFailure("原图格式或像素校验未通过，将保留错误状态") }
    return try RemoteAsset.hashFile(file)
  }
  func verifyLiveAsset(_ id: String, manifest: LivePhotoManifest) async throws {
    try checkPermission()
    guard
      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: lookupOptions())
        .firstObject,
      asset.mediaSubtypes.contains(.photoLive)
    else { throw SyncFailure("导入记录尚未确认为 Live Photo，保留记录并等待核对") }
    let resources = PHAssetResource.assetResources(for: asset)
    guard let photo = resources.first(where: { $0.type == .photo }),
      let movie = resources.first(where: { $0.type == .pairedVideo }),
      try await resourceHash(photo) == manifest.stillHash,
      try await resourceHash(movie) == manifest.movieHash
    else { throw SyncFailure("图库中 Live Photo 配对原片校验未通过，不会重复导入") }
  }
  func findExistingLive(filename: String, manifest: LivePhotoManifest) async throws -> String? {
    try checkPermission()
    let expected =
      ((filename as NSString).deletingPathExtension as NSString).lastPathComponent + ".heic"
    let options = lookupOptions()
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    let assets = PHAsset.fetchAssets(with: options)
    var candidates = [PHAsset]()
    assets.enumerateObjects { asset, _, _ in
      if asset.mediaSubtypes.contains(.photoLive),
        PHAssetResource.assetResources(for: asset).contains(where: {
          $0.type == .photo && $0.originalFilename.caseInsensitiveCompare(expected) == .orderedSame
        })
      {
        candidates.append(asset)
      }
    }
    for asset in candidates {
      let resources = PHAssetResource.assetResources(for: asset)
      guard let photo = resources.first(where: { $0.type == .photo }),
        let movie = resources.first(where: { $0.type == .pairedVideo })
      else { continue }
      if try await resourceHash(photo) == manifest.stillHash,
        try await resourceHash(movie) == manifest.movieHash
      {
        return asset.localIdentifier
      }
    }
    return nil
  }
  func importLive(_ pair: PreparedLivePhoto, asset: RemoteAsset) async throws -> String {
    let manifest = pair.manifest
    do {
      try Task.checkCancellation()
      try checkPermission()
      guard try RemoteAsset.hashFile(pair.still) == manifest.stillHash,
        try RemoteAsset.hashFile(pair.movie) == manifest.movieHash
      else { throw SyncFailure("配对文件在导入前发生变化") }
    } catch {
      throw ConfirmedImportFailure("导入前检查未通过，可重试：" + error.localizedDescription)
    }
    let journal = journalDirectory.appendingPathComponent(asset.key + ".json")
    let basename = ((asset.filename as NSString).lastPathComponent as NSString)
      .deletingPathExtension
    var identifier: String?
    // AppModel persists import intent first; the placeholder is journaled before this block returns.
    var journalError: Error?
    do {
      try await PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        let stillOptions = PHAssetResourceCreationOptions()
        stillOptions.originalFilename = basename + ".heic"
        let movieOptions = PHAssetResourceCreationOptions()
        movieOptions.originalFilename = basename + ".mov"
        request.addResource(with: .photo, fileURL: pair.still, options: stillOptions)
        request.addResource(with: .pairedVideo, fileURL: pair.movie, options: movieOptions)
        identifier = request.placeholderForCreatedAsset?.localIdentifier
        if let id = identifier {
          do {
            try JSONEncoder().encode(Receipt(photoID: id, livePhoto: manifest)).write(
              to: journal, options: .atomic)
            try FileManager.default.setAttributes(
              [.posixPermissions: 0o600], ofItemAtPath: journal.path)
          } catch { journalError = error }
        }
      }
    } catch {
      // PhotoKit's completed failure confirms there is no committed transaction to replay.
      try? FileManager.default.removeItem(at: journal)
      throw ConfirmedImportFailure()
    }
    if let journalError { throw journalError }
    guard let identifier else { throw SyncFailure("Live Photo 导入结果不确定，将先核对回执") }
    try await verifyLiveAsset(identifier, manifest: manifest)
    return identifier
  }
  /// A filename is only a candidate filter; bytes determine duplication.
  func findExisting(filename: String, hash: String, width: Int, height: Int) async throws -> String?
  {
    try checkPermission()
    let options = lookupOptions()
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    let assets = PHAsset.fetchAssets(with: options)
    var candidates = [(String, PHAssetResource)]()
    assets.enumerateObjects { a, _, _ in
      for r in PHAssetResource.assetResources(for: a)
      where r.type == .photo && r.originalFilename.caseInsensitiveCompare(filename) == .orderedSame
      { candidates.append((a.localIdentifier, r)) }
    }
    for (id, r) in candidates {
      try Task.checkCancellation()
      if try await resourceHash(r) == hash { return id }
    }
    return nil
  }
  private func resourceHash(_ resource: PHAssetResource) async throws -> String {
    let operation = PhotoReadOperation()
    return try await withTaskCancellationHandler(
      operation: {
        try await operation.read(resource)
      }, onCancel: { operation.cancel(CancellationError()) })
  }
  func importFile(_ file: URL, asset: RemoteAsset) async throws -> String {
    try checkPermission()
    let journal = journalDirectory.appendingPathComponent(asset.key + ".json")
    var identifier: String?
    var journalError: Error?
    try await PHPhotoLibrary.shared().performChanges {
      let request = PHAssetCreationRequest.forAsset()
      let options = PHAssetResourceCreationOptions()
      options.originalFilename = (asset.filename as NSString).lastPathComponent
      request.addResource(with: .photo, fileURL: file, options: options)
      identifier = request.placeholderForCreatedAsset?.localIdentifier
      if let id = identifier {
        do {
          try JSONEncoder().encode(Receipt(photoID: id)).write(to: journal, options: .atomic)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: journal.path)
        } catch { journalError = error }
      }
    }
    guard let identifier else { throw SyncFailure("Photos 未返回资产标识，下一轮将先核对重复项") }
    if journalError != nil
    { /* The successful return still lets the durable ledger retain the ID. */
    }
    return identifier
  }
}

/// Owns one PhotoKit resource request, including cancellation before its ID is assigned.
private final class PhotoReadOperation: @unchecked Sendable {
  private let lock = NSLock()
  private var id: PHAssetResourceDataRequestID?
  private var result: Result<String, Error>?
  private var continuation: CheckedContinuation<String, Error>?
  private var hash = SHA256()
  private var timeout: DispatchWorkItem?
  func read(_ resource: PHAssetResource) async throws -> String {
    try await withCheckedThrowingContinuation { c in
      lock.lock()
      if let result {
        lock.unlock()
        c.resume(with: result)
        return
      }
      continuation = c
      let timer = DispatchWorkItem { [weak self] in self?.cancel(SyncFailure("图库原片读取超时，任务已保留；稍后重试"))
      }
      timeout = timer
      lock.unlock()
      DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timer)
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = true
      let request = PHAssetResourceManager.default().requestData(
        for: resource, options: options,
        dataReceivedHandler: { [weak self] data in
          guard let self else { return }
          self.lock.lock()
          defer { self.lock.unlock() }
          if self.result == nil { self.hash.update(data: data) }
        },
        completionHandler: { [weak self] error in
          guard let self else { return }
          if error != nil {
            self.resolve(.failure(SyncFailure("图库中的同名原片无法读取，暂不导入以避免重复")))
            return
          }
          self.lock.lock()
          let digest = self.hash.finalize().map { String(format: "%02x", $0) }.joined()
          self.lock.unlock()
          self.resolve(.success(digest))
        })
      lock.lock()
      id = request
      let ended = result != nil
      lock.unlock()
      if ended { PHAssetResourceManager.default().cancelDataRequest(request) }
    }
  }
  func cancel(_ error: Error) { resolve(.failure(error), cancel: true) }
  private func resolve(_ newResult: Result<String, Error>, cancel: Bool = false) {
    lock.lock()
    guard result == nil else {
      lock.unlock()
      return
    }
    result = newResult
    let c = continuation
    continuation = nil
    let request = id
    let timer = timeout
    timeout = nil
    lock.unlock()
    timer?.cancel()
    if cancel, let request { PHAssetResourceManager.default().cancelDataRequest(request) }
    c?.resume(with: newResult)
  }
}
