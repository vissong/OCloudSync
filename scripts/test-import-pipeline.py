#!/usr/bin/env python3
"""Exercise AppModel queue wiring with offline cloud and Photos spies; no real library."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/OCloudSync/AppModel.swift').read_text()
def extract(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
methods = [extract(s) for s in ['  private struct ValidatedOriginal', '  private struct PreparedQueueItem', '  private func prepareOriginal(', '  private func processQueue(', '  private func finishQueueItem(', '  private func process(', '  private func recordFailure(', '  private func save(', '  private func recoverLocalWork(']]
harness = r'''
import Foundation
import ImageIO
import UniformTypeIdentifiers
struct ConfirmedImportFailure: Error {}
struct DateVerificationPending: Error { let photoID: String }
struct Pair { let manifest: LivePhotoManifest }
typealias PreparedLivePhoto = Pair
@MainActor enum LivePhotoConverter {
  static var cancelled = false, succeed = false, calls = 0
  static func prepare(_ file: URL, asset: RemoteAsset, hash: String) async throws -> Pair {
    calls += 1
    if cancelled { throw CancellationError() }
    if succeed { return Pair(manifest: LivePhotoManifest(sourceHash: hash,stillHash: "still",movieHash: "movie",
      width: asset.width,height: asset.height,duration: 1,stillTime: 0.5,hasAudio: false,usedFallbackTime: true)) }
    throw SyncFailure("conversion failed")
  }
}
@MainActor final class Web {
  var requiresLogin = false, needsRescan = false, active = 0, maxActive = 0
  var downloads = [String](), failID: String?, authID: String?
  var onDownload: (() -> Void)?
  var motionData = Data()
  func download(_ asset: RemoteAsset, to file: URL) async throws -> URL {
    active += 1; maxActive = max(maxActive, active)
    defer { active -= 1 }
    downloads.append(asset.remoteID); onDownload?()
    try await Task.sleep(nanoseconds: 5_000_000)
    onDownload?()
    if asset.remoteID == authID { throw SessionAccessFailure(.loginRequired) }
    if asset.remoteID == failID { throw SyncFailure("download failed") }
    try (asset.isMotionJPEG ? motionData : Data(asset.remoteID.utf8)).write(to: file)
    return file
  }
}
@MainActor final class PhotoImporter {
  struct Receipt {
    var photoID: String, livePhoto: LivePhotoManifest?, sourceHash: String?
    var mediaDate: ResolvedMediaDate?, dateVerified: Bool?
    var staticFallback: StaticFallbackInfo?
    var videoCompatibility: VideoCompatibilityInfo?
  }
  var receipts = [String: Receipt](), hashes = [String: String]()
  var imports = [String](), active = 0, maxActive = 0, validates = 0
  var rejectID: String?, slow = false, committedDespiteCancellation = false
  var rejectOnCancellation = false
  var onImport: (() -> Void)?
  var byName = [String:String](), staticVerifications = 0
  var metadataLookups = 0, hashLookups = 0
  func checkPermission() throws {}
  func receipt(for key: String) throws -> Receipt? { receipts[key] }
  func exists(_ id: String) -> Bool { hashes[id] != nil }
  func validate(_ file: URL, asset: RemoteAsset) async throws -> String {
    validates += 1
    _ = try Data(contentsOf: file)
    if asset.isMotionJPEG { return try RemoteAsset.hashFile(file) }
    return asset.remoteID.hasPrefix("same") ? "same-hash" : asset.remoteID
  }
  func verifyLiveAsset(_ id: String, manifest: LivePhotoManifest) async throws {}
  func verifyOriginalVideo(_ id: String, hash: String) async throws {
    guard hashes[id] == hash else { throw SyncFailure("video resource mismatch") }
  }
  func verifyStaticAsset(_ id: String, hash: String) async throws {
    staticVerifications += 1
    guard hashes[id] == hash else { throw SyncFailure("static resource mismatch") }
  }
  func findExistingByNameAndDate(asset: RemoteAsset, file: URL) throws -> String? {
    metadataLookups += 1
    guard let id = byName[asset.remoteID], exists(id) else { return nil }
    return id
  }
  func confirmImportedDate(_ key: String, id: String, expected: Date) throws {}
  func findExistingLive(filename: String, manifest: LivePhotoManifest) async throws -> String? { nil }
  func findExisting(asset: RemoteAsset, hash: String) async throws -> String? {
    hashLookups += 1
    return hashes.first { $0.value == hash }?.key
  }
  func importLive(_ pair: Pair, asset: RemoteAsset) async throws -> String { throw SyncFailure("not used") }
  func importFile(_ file: URL, asset: RemoteAsset, hash: String, staticFallback: StaticFallbackInfo? = nil,
    videoCompatibility: VideoCompatibilityInfo? = nil) async throws -> String {
    active += 1; maxActive = max(maxActive, active)
    defer { active -= 1 }
    onImport?()
    if rejectOnCancellation {
      try? await Task.sleep(nanoseconds: 60_000_000_000)
      throw ConfirmedImportFailure()
    } else if committedDespiteCancellation {
      // PhotoKit may finish an already submitted transaction after task cancellation.
      await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { continuation.resume() }
      }
    } else {
      try await Task.sleep(nanoseconds: slow ? 60_000_000_000 : 20_000_000)
    }
    if asset.remoteID == rejectID { throw ConfirmedImportFailure() }
    imports.append(asset.remoteID)
    hashes[asset.remoteID] = hash
    receipts[asset.key] = Receipt(photoID: asset.remoteID,livePhoto: nil,
      sourceHash: videoCompatibility?.sourceHash ?? staticFallback?.sourceHash ?? hash,
      staticFallback: staticFallback,videoCompatibility: videoCompatibility)
    return asset.remoteID
  }
}
@MainActor final class Model {
  var ledger = Ledger(), fatal: String?, status = "", rangeStatus = ""
  var completed = 0, total = 0, importProgress: ImportProgress?
  var localRecoveryProgress: ImportProgress?, importProgressIsRange = false
  var processingKey: String?
  var importer: PhotoImporter?, cache: URL?
  let web = Web()
  var failSave = false
  func persist(_ changed: Ledger) throws {
    if failSave { fatal = "storage"; throw SyncFailure("storage") }
    ledger = changed
  }
  func run(_ records: [SyncRecord], _ importer: PhotoImporter, _ cache: URL) async throws {
    try await processQueue(records, importer: importer, cache: cache, present: Set(records.map(\.id)))
  }
  func recover(_ importer: PhotoImporter, _ cache: URL) async throws {
    self.importer = importer; self.cache = cache
    try await recoverLocalWork()
  }
__METHODS__
}
@main struct Regression {
 @MainActor static func main() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  func setup(_ ids: [String]) -> (Model, PhotoImporter, [SyncRecord]) {
    let m = Model(), p = PhotoImporter()
    let records = ids.map { id in SyncRecord(asset: RemoteAsset(account: UUID().uuidString,
      remoteID: id, fileID: id, filename: id+".jpg", bytes: 100, width: 10, height: 10,
      mediaType: 1, version: "v1", isMotion: false), state: .pending) }
    // Model the single authenticated account of a production scan.
    let account = UUID().uuidString
    let normalized = records.map { r -> SyncRecord in
      var a = r.asset; a.account = account; return SyncRecord(asset: a, state: .pending)
    }
    for r in normalized { m.ledger.records[r.id] = r }
    return (m,p,normalized)
  }
  let (m,p,items) = setup(["same1","same2","bad","last"])
  var overlap = false
  m.web.onDownload = { overlap = overlap || p.active > 0 }
  m.web.failID = "bad"
  p.byName["same2"] = "same1"
  try await m.run(items,p,folder)
  precondition(overlap && m.web.maxActive == 1 && p.maxActive == 1)
  precondition(p.imports == ["same1","last"], "duplicate raced or later item was lost")
  precondition(m.importProgress?.imported == 2 && m.importProgress?.duplicates == 1)
  precondition(m.importProgress?.failed == 1 && m.completed == 4)
  precondition(p.validates == 3, "prepared originals were redundantly validated")
  precondition(m.ledger.records[items[2].id]?.state == .failed)
  // A downloaded item survives stop/restart without another network request.
  let (cached,cp,ci) = setup(["cached"])
  let file = folder.appendingPathComponent(ci[0].id+".jpg")
  try Data("cached".utf8).write(to: file)
  try await cached.run(ci,cp,folder)
  precondition(cached.web.downloads.isEmpty && cp.imports == ["cached"])
  // Local recovery and the subsequent remote queue both retain their own results.
  let (recovery,lp,li) = setup(["local","remote"])
  try Data("local".utf8).write(to: folder.appendingPathComponent(li[0].id+".jpg"))
  try await recovery.recover(lp,folder)
  precondition(recovery.localRecoveryProgress?.imported == 1)
  precondition(recovery.localRecoveryProgress?.total == 1)
  try await recovery.run([li[1]],lp,folder)
  precondition(recovery.localRecoveryProgress?.imported == 1 && recovery.importProgress?.imported == 1)
  precondition(lp.imports == ["local","remote"])
  // A known pre-commit receipt is reconciled without fetching an original.
  let (receipted,rp,ri) = setup(["receipt"])
  rp.hashes["receipt"] = "hash"
  rp.receipts[ri[0].id] = PhotoImporter.Receipt(photoID:"receipt", livePhoto:nil, sourceHash:"hash")
  try await receipted.run(ri,rp,folder)
  precondition(receipted.web.downloads.isEmpty && rp.imports.isEmpty)
  precondition(receipted.importProgress?.imported == 1)
  // Unknown static commits cannot be re-prepared or accepted on metadata alone.
  let (unknown,xp,xi) = setup(["unknown-static"])
  var unknownRecord = xi[0]; unknownRecord.state = .importing; unknownRecord.sha256 = "expected-original"
  unknown.ledger.records[unknownRecord.id] = unknownRecord
  xp.hashes["foreign"] = "different-original"; xp.byName["unknown-static"] = "foreign"
  try await unknown.run([unknownRecord],xp,folder)
  precondition(unknown.web.downloads.isEmpty && xp.imports.isEmpty && xp.metadataLookups == 0)
  precondition(xp.hashLookups == 1 && unknown.ledger.records[unknownRecord.id]?.state == .importing)
  xp.hashes["confirmed"] = "expected-original"
  try await unknown.run([unknown.ledger.records[unknownRecord.id]!],xp,folder)
  precondition(unknown.ledger.records[unknownRecord.id]?.state == .imported)
  precondition(unknown.ledger.records[unknownRecord.id]?.photoID == "confirmed" && xp.imports.isEmpty)
  // Auth failure cancels/joins the concurrent library stage before recovery.
  let (auth,ap,ai) = setup(["current","expired","never"])
  ap.slow = true; auth.web.authID = "expired"
  do { try await auth.run(ai,ap,folder); preconditionFailure("expected auth failure") }
  catch is SessionAccessFailure {}
  precondition(auth.web.active == 0 && ap.active == 0 && ap.imports.isEmpty)
  precondition(!auth.web.downloads.contains("never"))
  auth.ledger.recoverInterrupted()
  precondition(auth.ledger.records[ai[1].id]?.state == .pending)
  // A commit already in flight must be journaled before cancellation recovery returns.
  let (committed,kp,ki) = setup(["committed","expired","never"])
  kp.committedDespiteCancellation = true; committed.web.authID = "expired"
  do { try await committed.run(ki,kp,folder); preconditionFailure("expected auth failure") }
  catch is SessionAccessFailure {}
  precondition(kp.active == 0 && kp.imports == ["committed"])
  precondition(committed.ledger.records[ki[0].id]?.state == .imported)
  precondition(committed.ledger.records[ki[0].id]?.photoID == "committed")
  // Ledger failure cancels the other stage and preserves uncommitted work.
  let (storage,sp,si) = setup(["writing","next","never"])
  sp.slow = true; sp.onImport = { storage.failSave = true }
  do { try await storage.run(si,sp,folder); preconditionFailure("expected storage failure") }
  catch {}
  precondition(storage.web.active == 0 && sp.active == 0 && sp.imports.isEmpty)
  precondition(storage.fatal != nil && !storage.web.downloads.contains("never"))
  // Explicit cancellation drains both stages without inventing a failure outcome.
  let (cancel,dp,di) = setup(["cancel","prefetch","never"])
  dp.slow = true
  let task = Task { try await cancel.run(di,dp,folder) }
  while dp.active == 0 { await Task.yield() }
  task.cancel()
  do { try await task.value; preconditionFailure("expected cancellation") }
  catch is CancellationError {}
  precondition(cancel.web.active == 0 && dp.active == 0 && cancel.importProgress?.failed == 0)
  // A prefetch failure already persisted must remain visible when its consumer is cancelled.
  let (buffered,bp,bi) = setup(["slow","failed-prefetch","never"])
  bp.slow = true; buffered.web.failID = "failed-prefetch"
  let bufferedTask = Task { try await buffered.run(bi,bp,folder) }
  while buffered.ledger.records[bi[1].id]?.state != .failed { await Task.yield() }
  bufferedTask.cancel()
  do { try await bufferedTask.value; preconditionFailure("expected cancellation") }
  catch is CancellationError {}
  precondition(buffered.importProgress?.failed == 1 && buffered.importProgress?.processed == 1,
    "already persisted prefetch failure disappeared from progress")
  precondition(buffered.importProgress?.remaining == 2 && buffered.web.active == 0 && bp.active == 0)
  // A confirmed PhotoKit non-commit is persisted even if stop arrived concurrently.
  let (rejected,jp,ji) = setup(["rejected"])
  jp.rejectOnCancellation = true
  let rejectedTask = Task { try await rejected.run(ji,jp,folder) }
  while jp.active == 0 { await Task.yield() }
  rejectedTask.cancel()
  do { try await rejectedTask.value; preconditionFailure("expected cancellation") }
  catch is CancellationError {}
  precondition(rejected.ledger.records[ji[0].id]?.state == .failed)
  precondition(rejected.importProgress?.failed == 1 && rejected.importProgress?.processed == 1)
  // Identical content with different names is not sufficient under the requested rule.
  let (different,np,ni) = setup(["same3","same4"])
  try await different.run(ni,np,folder)
  precondition(np.imports == ["same3","same4"])
  // Use a real JPEG plus corrupt trailer to exercise static extraction through AppModel.
  let jpeg = folder.appendingPathComponent("fixture.jpg")
  let context = CGContext(data:nil,width:10,height:10,bitsPerComponent:8,bytesPerRow:40,
    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
  let dest = CGImageDestinationCreateWithURL(jpeg as CFURL,UTType.jpeg.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(dest,context.makeImage()!,[kCGImagePropertyExifDictionary:
    ["DateTimeOriginal":"2026:04:05 11:28:12"]] as CFDictionary)
  precondition(CGImageDestinationFinalize(dest))
  var motionData = try Data(contentsOf:jpeg); motionData.append(Data("broken video".utf8))
  func motionSetup(_ name: String) -> (Model,PhotoImporter,[SyncRecord]) {
    let (m,p,records) = setup([name]); var r = records[0]
    r.asset.isMotion = true; r.asset.bytes = Int64(motionData.count)
    m.ledger.records[r.id] = r; m.web.motionData = motionData
    return (m,p,[r])
  }
  let (fallback,fp,fi) = motionSetup("fallback")
  try await fallback.run(fi,fp,folder)
  let saved = fallback.ledger.records[fi[0].id]!
  precondition(saved.state == .imported && saved.staticFallback != nil && saved.livePhoto == nil)
  precondition(saved.sha256 == RemoteAsset.digest(motionData) && fp.imports == ["fallback"])
  precondition(fp.receipts[saved.id]?.staticFallback == saved.staticFallback)
  let previousCalls = LivePhotoConverter.calls
  try await fallback.run([saved],fp,folder)
  precondition(fp.imports.count == 1 && fp.staticVerifications == 1 && LivePhotoConverter.calls == previousCalls)
  let (cancelMotion,mp,mi) = motionSetup("cancel-motion")
  LivePhotoConverter.cancelled = true
  do { try await cancelMotion.run(mi,mp,folder); preconditionFailure("conversion cancellation ignored") }
  catch is CancellationError {}
  LivePhotoConverter.cancelled = false
  precondition(mp.imports.isEmpty && cancelMotion.ledger.records[mi[0].id]?.staticFallback == nil)
  let (uncertain,up,ui) = motionSetup("uncertain-live")
  var pendingLive = ui[0]; pendingLive.state = .importing; uncertain.ledger.records[pendingLive.id] = pendingLive
  try await uncertain.run([pendingLive],up,folder)
  precondition(up.imports.isEmpty && uncertain.ledger.records[pendingLive.id]?.staticFallback == nil)
  let (rejectedLive,vp,vi) = motionSetup("live-write-fails")
  LivePhotoConverter.succeed = true
  try await rejectedLive.run(vi,vp,folder)
  LivePhotoConverter.succeed = false
  precondition(vp.imports.isEmpty && rejectedLive.ledger.records[vi[0].id]?.staticFallback == nil)
  precondition(rejectedLive.ledger.records[vi[0].id]?.state == .importing)
  // Recovery must compare the actual imported video, preserving the original source hash.
  for withReceipt in [true, false] {
    let (videoModel, videoImporter, videoRecords) = setup(["compatible-video"])
    var video = videoRecords[0]
    video.asset.mediaType = 3; video.asset.filename = "compatible-video.mp4"
    video.state = .importing; video.sha256 = "original-video"
    let info = VideoCompatibilityInfo(sourceHash: "original-video", importHash: "compatible-video")
    videoImporter.hashes["existing-video"] = info.importHash
    if withReceipt {
      videoImporter.receipts[video.id] = PhotoImporter.Receipt(photoID: "existing-video", livePhoto: nil,
        sourceHash: info.sourceHash, videoCompatibility: info)
    } else { video.videoCompatibility = info }
    videoModel.ledger.records[video.id] = video
    try await videoModel.run([video],videoImporter,folder)
    let restoredVideo = videoModel.ledger.records[video.id]!
    precondition(restoredVideo.state == .imported && restoredVideo.photoID == "existing-video")
    precondition(restoredVideo.sha256 == "original-video" && restoredVideo.videoCompatibility == info)
    precondition(videoImporter.imports.isEmpty && videoModel.web.downloads.isEmpty)
  }
  print("PASS: production queue overlap, serialized dedup, cache and receipt recovery, compatible-video recovery, per-file failure, auth/storage/cancellation drain, outcome progress")
 }
}
'''.replace('__METHODS__', '\n'.join(methods))
with tempfile.TemporaryDirectory(prefix='ocloud-pipeline-') as folder:
    swift = Path(folder) / 'Regression.swift'
    binary = Path(folder) / 'regression'
    swift.write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', *map(str, sorted((root / 'Sources/SyncCore').glob('*.swift'))), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
