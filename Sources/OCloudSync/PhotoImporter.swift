import CryptoKit
import Foundation
import ImageIO
import Photos
import SyncCore

struct ConfirmedImportFailure: LocalizedError {
  let errorDescription: String?
  init(_ message: String = "系统明确拒绝了 Live Photo 导入，已保留原图与配对资源，将稍后重试") { errorDescription = message }
}
struct DateVerificationPending: LocalizedError {
  let photoID: String
  var errorDescription: String? { "文件已导入，拍摄时间待修复；请在任务记录中检查拍摄时间" }
}

final class PhotoImporter {
  struct Receipt: Codable {
    let photoID: String
    var livePhoto: LivePhotoManifest?
    var sourceHash: String?
    var mediaDate: ResolvedMediaDate?
    var dateVerified: Bool?
    var pendingDate: ResolvedMediaDate?
    var dateBeforeRepair: Date?
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
  func lookupOptions() -> PHFetchOptions {
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
  func validate(_ file: URL, asset: RemoteAsset) async throws -> String {
    try await MediaFileValidator.validate(file, asset: asset)
  }
  func verifyOriginalVideo(_ id: String, hash: String) async throws {
    try checkPermission()
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: lookupOptions()).firstObject,
      asset.mediaType == .video,
      let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .video }),
      try await resourceHash(resource) == hash
    else { throw SyncFailure("图库视频原文件校验未通过，保留回执并暂停重复导入") }
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
    let mediaDate: ResolvedMediaDate
    do {
      try Task.checkCancellation()
      try checkPermission()
      guard try RemoteAsset.hashFile(pair.still) == manifest.stillHash,
        try RemoteAsset.hashFile(pair.movie) == manifest.movieHash
      else { throw SyncFailure("配对文件在导入前发生变化") }
      mediaDate = try MediaDateResolver.resolve(asset: asset, file: pair.still)
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
        request.creationDate = mediaDate.date
        let stillOptions = PHAssetResourceCreationOptions()
        stillOptions.originalFilename = basename + ".heic"
        let movieOptions = PHAssetResourceCreationOptions()
        movieOptions.originalFilename = basename + ".mov"
        request.addResource(with: .photo, fileURL: pair.still, options: stillOptions)
        request.addResource(with: .pairedVideo, fileURL: pair.movie, options: movieOptions)
        identifier = request.placeholderForCreatedAsset?.localIdentifier
        if let id = identifier {
          do {
            try JSONEncoder().encode(Receipt(photoID: id, livePhoto: manifest, mediaDate: mediaDate)).write(
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
    try confirmImportedDate(asset.key, id: identifier, expected: mediaDate.date)
    return identifier
  }
  /// A filename is only a candidate filter; bytes determine duplication.
  func findExisting(asset: RemoteAsset, hash: String) async throws -> String?
  {
    try checkPermission()
    let options = lookupOptions()
    options.predicate = NSPredicate(format: "mediaType == %d", (asset.isVideo ? PHAssetMediaType.video : .image).rawValue)
    let assets = PHAsset.fetchAssets(with: options)
    var candidates = [(String, PHAssetResource)]()
    assets.enumerateObjects { a, _, _ in
      for r in PHAssetResource.assetResources(for: a)
      where r.type == (asset.isVideo ? .video : .photo) && r.originalFilename.caseInsensitiveCompare(asset.filename) == .orderedSame
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
  func importFile(_ file: URL, asset: RemoteAsset, hash: String) async throws -> String {
    let mediaDate: ResolvedMediaDate
    do {
      try Task.checkCancellation()
      try checkPermission()
      guard try await validate(file, asset: asset) == hash else {
        throw SyncFailure("原文件在导入前发生变化")
      }
      mediaDate = try MediaDateResolver.resolve(asset: asset, file: file)
      try Task.checkCancellation()
    } catch {
      throw ConfirmedImportFailure("导入前检查未通过，可重试：" + error.localizedDescription)
    }
    let journal = journalDirectory.appendingPathComponent(asset.key + ".json")
    var identifier: String?
    var journalError: Error?
    do {
      try await PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        request.creationDate = mediaDate.date
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = (asset.filename as NSString).lastPathComponent
        request.addResource(with: asset.isVideo ? .video : .photo, fileURL: file, options: options)
        identifier = request.placeholderForCreatedAsset?.localIdentifier
        if let id = identifier {
          do {
            try JSONEncoder().encode(Receipt(photoID: id, sourceHash: hash, mediaDate: mediaDate)).write(to: journal, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
          } catch { journalError = error }
        }
      }
    } catch {
      try? FileManager.default.removeItem(at: journal)
      throw ConfirmedImportFailure("系统明确拒绝了照片或视频导入，已保留原文件，将稍后重试")
    }
    if let journalError { throw journalError }
    guard let identifier else { throw SyncFailure("图库导入结果不确定，将先核对回执") }
    if asset.isVideo { try await verifyOriginalVideo(identifier, hash: hash) }
    try confirmImportedDate(asset.key, id: identifier, expected: mediaDate.date)
    return identifier
  }

  func verifyCreationDate(_ id: String, expected: Date) throws {
    try checkPermission()
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: lookupOptions()).firstObject,
      let actual = asset.creationDate, abs(actual.timeIntervalSince(expected)) < 1
    else { throw SyncFailure("图库拍摄时间尚未确认，已保留回执；请检查并修复已有日期") }
  }

  func confirmImportedDate(_ key: String, id: String, expected: Date) throws {
    try checkPermission()
    guard exists(id), var saved = try receipt(for: key), saved.photoID == id,
      saved.mediaDate?.date == expected else { throw SyncFailure("已提交资源的日期回执尚未确认，保留记录等待核对") }
    do { try verifyCreationDate(id, expected: expected) }
    catch { throw DateVerificationPending(photoID: id) }
    saved.dateVerified = true
    let journal = journalDirectory.appendingPathComponent(key + ".json")
    try JSONEncoder().encode(saved).write(to: journal, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
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
      DispatchQueue.global().asyncAfter(deadline: .now() + (resource.type == .video ? 1800 : 120), execute: timer)
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
