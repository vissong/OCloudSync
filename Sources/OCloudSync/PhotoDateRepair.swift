import Foundation
import Photos
import SyncCore

struct PhotoDateRepair: Codable, Identifiable {
  var id: String { key }
  let key: String
  let photoID: String
  let filename: String
  let isVideo: Bool
  let hasWarning: Bool
  let before: Date?
  let target: ResolvedMediaDate
}
struct PhotoDatePreview: Codable {
  var items = [PhotoDateRepair]()
  var correct = 0
  var skipped = 0
  var checked = 0
}

extension PhotoImporter {
  func previewDates(_ records: [SyncRecord], cache: URL,
    progress: @escaping (Int, Int) async -> Void) async throws -> PhotoDatePreview {
    try checkPermission()
    var preview = PhotoDatePreview()
    for record in records {
      try Task.checkCancellation()
      preview.checked += 1
      if let item = try dateRepairCandidate(record, cache: cache) {
        if DateRepairPolicy.same(item.before, item.target.date) && !item.hasWarning { preview.correct += 1 }
        else { preview.items.append(item) }
      } else { preview.skipped += 1 }
      await progress(preview.checked, records.count)
      await Task.yield()
    }
    try Task.checkCancellation()
    return preview
  }

  private func ownedReceipt(_ record: SyncRecord) throws -> Receipt? {
    guard let receipt = try receipt(for: record.id),
      DateRepairPolicy.owns(record, photoID: receipt.photoID,
        hash: receipt.livePhoto?.sourceHash ?? receipt.sourceHash),
      receipt.livePhoto == record.livePhoto
    else { return nil }
    return receipt
  }

  private func dateRepairCandidate(_ record: SyncRecord, cache: URL) throws -> PhotoDateRepair? {
    guard let receipt = try ownedReceipt(record),
      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [receipt.photoID], options: lookupOptions()).firstObject,
      asset.mediaType == (record.asset.isVideo ? .video : .image)
    else { return nil }
    if let pending = receipt.pendingDate {
      // A committed change may need only its receipt finalized. A third date is a manual edit.
      guard DateRepairPolicy.same(asset.creationDate, receipt.dateBeforeRepair)
        || DateRepairPolicy.same(asset.creationDate, pending.date) else { return nil }
      return PhotoDateRepair(key: record.id, photoID: receipt.photoID, filename: record.asset.filename,
        isVideo: record.asset.isVideo, hasWarning: true, before: asset.creationDate, target: pending)
    }
    guard DateRepairPolicy.mayRepair(current: asset.creationDate,
      previousManaged: receipt.dateVerified == true ? receipt.mediaDate?.date : nil) else { return nil }
    let date: ResolvedMediaDate
    if let saved = receipt.mediaDate {
      // A no-offset EXIF date was resolved in the time zone at import. Keep that instant stable.
      date = saved
    } else {
      let file = cache.appendingPathComponent(record.id + "." + (record.asset.filename as NSString).pathExtension.lowercased())
      // Legacy records without a cloud date must use their verified original, never a replacement file.
      if record.asset.captureDate == nil {
        guard let hash = record.sha256, (try? RemoteAsset.hashFile(file)) == hash else { return nil }
      }
      guard let resolved = try? MediaDateResolver.resolve(asset: record.asset, file: file) else { return nil }
      date = resolved
    }
    return PhotoDateRepair(key: record.id, photoID: receipt.photoID, filename: record.asset.filename,
      isVideo: record.asset.isVideo, hasWarning: record.error != nil, before: asset.creationDate, target: date)
  }

  /// Write the complete before/after plan before any PhotoKit change; this is private local data.
  func saveDateAudit(_ preview: PhotoDatePreview) throws -> URL {
    let directory = journalDirectory.deletingLastPathComponent().appendingPathComponent("date-repairs")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let file = directory.appendingPathComponent(UUID().uuidString + ".json")
    try JSONEncoder().encode(preview).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return file
  }

  func repairDate(_ item: PhotoDateRepair, record: SyncRecord) async throws {
    try Task.checkCancellation()
    try checkPermission()
    guard record.id == item.key, var receipt = try ownedReceipt(record), receipt.photoID == item.photoID,
      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.photoID], options: lookupOptions()).firstObject,
      asset.mediaType == (item.isVideo ? .video : .image)
    else { throw SyncFailure("导入回执或图库项目已变化，请重新检查日期") }
    let journal = journalDirectory.appendingPathComponent(item.key + ".json")
    if !DateRepairPolicy.same(asset.creationDate, item.target.date) {
      guard DateRepairPolicy.same(asset.creationDate, item.before), asset.canPerform(.properties) else {
        throw SyncFailure("图库日期已被修改或不可编辑，已跳过；请重新检查日期")
      }
      receipt.pendingDate = item.target
      receipt.dateBeforeRepair = asset.creationDate
      try JSONEncoder().encode(receipt).write(to: journal, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest(for: asset).creationDate = item.target.date
      }
    }
    try verifyCreationDate(item.photoID, expected: item.target.date)
    // Keep the pre-commit intent until readback and final receipt persistence both succeed.
    receipt.mediaDate = item.target
    receipt.dateVerified = true
    receipt.pendingDate = nil
    receipt.dateBeforeRepair = nil
    try JSONEncoder().encode(receipt).write(to: journal, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
  }
}
