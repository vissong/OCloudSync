#!/usr/bin/env python3
"""Exercise production importFile with a PhotoKit transaction spy; no Photos access."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / "Sources/OCloudSync/PhotoImporter.swift").read_text()
def extract(signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]
harness = r'''
import Foundation
struct SyncFailure: Error { init(_ message: String) {} }
struct ConfirmedImportFailure: Error { init(_ message: String = "rejected") {} }
__DATE_FAILURE__
struct RemoteAsset {
  let key: String; let filename: String; let isVideo: Bool
  static func hashFile(_ file: URL) throws -> String { "hash" }
}
struct ResolvedMediaDate: Codable { let date: Date }
struct StaticFallbackInfo: Codable { let sourceHash: String; let stillHash: String; let reason: String }
enum MediaDateResolver {
  static let expected = Date(timeIntervalSince1970: 1_780_000_000)
  static func resolve(asset: RemoteAsset, file: URL) throws -> ResolvedMediaDate { ResolvedMediaDate(date: expected) }
}
struct LivePhotoManifest: Codable { var stillHash = "hash", movieHash = "hash" }
struct PreparedLivePhoto { let still: URL, movie: URL; let manifest = LivePhotoManifest() }
enum ResourceType { case photo, video, pairedVideo }
final class PHAssetResourceCreationOptions { var originalFilename = "" }
struct Placeholder { let localIdentifier = "synthetic-receipt" }
final class PHAssetCreationRequest {
  static var resources = [ResourceType]()
  static var filename = ""
  static var dates = [Date]()
  var creationDate: Date? { didSet { if let date = creationDate { Self.dates.append(date) } } }
  static func forAsset() -> PHAssetCreationRequest { PHAssetCreationRequest() }
  var placeholderForCreatedAsset: Placeholder? { Placeholder() }
  func addResource(with type: ResourceType, fileURL: URL, options: PHAssetResourceCreationOptions) {
    Self.resources.append(type); Self.filename = options.originalFilename
  }
}
final class PHPhotoLibrary {
  static let library = PHPhotoLibrary()
  var reject = false
  static func shared() -> PHPhotoLibrary { library }
  func performChanges(_ changes: () -> Void) async throws {
    changes()
    if reject { throw SyncFailure("confirmed rejection") }
  }
}
final class ImportSpy {
  __RECEIPT__
  let journalDirectory: URL
  var allowed = true
  var validationHash = "hash"
  var verificationFails = false
  var dateFails = false
  var verified = false
  init(_ directory: URL) { journalDirectory = directory }
  func exists(_ id: String) -> Bool { true }
  func checkPermission() throws { if !allowed { throw SyncFailure("denied") } }
  func validate(_ file: URL, asset: RemoteAsset) async throws -> String { validationHash }
  func verifyOriginalVideo(_ id: String, hash: String) async throws {
    verified = true
    if verificationFails { throw SyncFailure("uncertain verification") }
  }
  func verifyLiveAsset(_ id: String, manifest: LivePhotoManifest) async throws {}
  func verifyCreationDate(_ id: String, expected: Date) throws {
    if dateFails { throw SyncFailure("date mismatch") }
    guard expected == MediaDateResolver.expected, PHAssetCreationRequest.dates.last == expected else { fatalError("creation date not set") }
  }
__READ_RECEIPT__
__CONFIRM_DATE__
__METHOD__
}
@main struct Regression {
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let spy = ImportSpy(root), file = root.appendingPathComponent("original.mp4")
    let asset = RemoteAsset(key: "video", filename: "folder/original.mp4", isVideo: true)
    let journal = root.appendingPathComponent("video.json")
    _ = try await spy.importFile(file, asset: asset, hash: "hash")
    precondition(PHAssetCreationRequest.dates.last == MediaDateResolver.expected, "video capture date missing")
    guard PHAssetCreationRequest.resources == [.video], spy.verified,
      PHAssetCreationRequest.filename == "original.mp4" else { fatalError("wrong import resource") }
    let receipt = try JSONDecoder().decode(ImportSpy.Receipt.self, from: Data(contentsOf: journal))
    guard receipt.sourceHash == "hash" else { fatalError("missing original hash") }
    precondition(receipt.mediaDate?.date == MediaDateResolver.expected, "missing date receipt")
    precondition(receipt.dateVerified == true, "verified date not persisted")
    PHPhotoLibrary.library.reject = true
    do { _ = try await spy.importFile(file, asset: asset, hash: "hash"); fatalError("rejection ignored") }
    catch is ConfirmedImportFailure {}
    guard !FileManager.default.fileExists(atPath: journal.path) else { fatalError("rejected transaction journal retained") }
    PHPhotoLibrary.library.reject = false
    spy.verificationFails = true
    do { _ = try await spy.importFile(file, asset: asset, hash: "hash"); fatalError("verification ignored") }
    catch is ConfirmedImportFailure { fatalError("committed import was classified uncommitted") } catch {}
    guard FileManager.default.fileExists(atPath: journal.path) else { fatalError("uncertain receipt discarded") }
    let before = PHAssetCreationRequest.resources.count
    spy.allowed = false
    do { _ = try await spy.importFile(file, asset: asset, hash: "hash"); fatalError("permission ignored") }
    catch is ConfirmedImportFailure {}
    guard PHAssetCreationRequest.resources.count == before else { fatalError("permission failure started import") }
    spy.allowed = true; spy.verificationFails = false; spy.validationHash = "changed"
    do { _ = try await spy.importFile(file, asset: asset, hash: "hash"); fatalError("changed file imported") }
    catch is ConfirmedImportFailure {}
    guard PHAssetCreationRequest.resources.count == before else { fatalError("changed file started import") }
    spy.validationHash = "hash"
    _ = try await spy.importFile(file, asset: RemoteAsset(key: "photo", filename: "a.jpg", isVideo: false), hash: "hash")
    guard PHAssetCreationRequest.resources.last == .photo else { fatalError("photo path changed") }
    precondition(PHAssetCreationRequest.dates.count == 4, "photo capture date missing")
    _ = try await spy.importLive(PreparedLivePhoto(still: file, movie: file), asset: RemoteAsset(key: "live", filename: "live.jpg", isVideo: false))
    precondition(PHAssetCreationRequest.dates.count == 5, "Live Photo capture date missing")
    let liveReceipt = try JSONDecoder().decode(ImportSpy.Receipt.self, from: Data(contentsOf: root.appendingPathComponent("live.json")))
    precondition(liveReceipt.mediaDate?.date == MediaDateResolver.expected)
    let fallback = StaticFallbackInfo(sourceHash: "motion-original",stillHash: "hash",reason: "conversion failed")
    _ = try await spy.importFile(file, asset: RemoteAsset(key: "fallback",filename: "motion.jpg",isVideo: false),
      hash: "hash",staticFallback: fallback)
    let staticReceipt = try JSONDecoder().decode(ImportSpy.Receipt.self,from: Data(contentsOf: root.appendingPathComponent("fallback.json")))
    precondition(staticReceipt.sourceHash == "motion-original" && staticReceipt.staticFallback?.stillHash == "hash")
    precondition(staticReceipt.livePhoto == nil && staticReceipt.dateVerified == true)
    precondition(staticReceipt.mediaDate?.date == MediaDateResolver.expected)
    precondition(PHAssetCreationRequest.resources.last == .photo && PHAssetCreationRequest.filename == "motion.jpg")
    precondition(PHAssetCreationRequest.dates.count == 6)
    spy.dateFails = true
    let pending = RemoteAsset(key: "date-pending", filename: "pending.mp4", isVideo: true)
    do { _ = try await spy.importFile(file, asset: pending, hash: "hash"); fatalError("date mismatch ignored") }
    catch let error as DateVerificationPending { precondition(error.photoID == "synthetic-receipt") }
    catch is ConfirmedImportFailure { fatalError("committed resource classified as not imported") }
    let pendingReceipt = try spy.receipt(for: pending.key)
    precondition(pendingReceipt?.mediaDate != nil && pendingReceipt?.dateVerified != true)
    spy.dateFails = false
    try spy.confirmImportedDate(pending.key, id: "synthetic-receipt", expected: MediaDateResolver.expected)
    let recoveredReceipt = try spy.receipt(for: pending.key)
    precondition(recoveredReceipt?.dateVerified == true)
    print("PASS: video/photo/live capture dates, receipts, resource type, confirmed rejection, uncertain verification, preflight guards")
  }
}
'''.replace("__METHOD__", extract("  func importFile(") + "\n" + extract("  func importLive("))
harness = harness.replace("__RECEIPT__", extract("  struct Receipt:"))
harness = harness.replace("__DATE_FAILURE__", extract("struct DateVerificationPending:"))
harness = harness.replace("__READ_RECEIPT__", extract("  func receipt("))
harness = harness.replace("__CONFIRM_DATE__", extract("  func confirmImportedDate("))
with tempfile.TemporaryDirectory(prefix="ocloud-video-import-") as folder:
    swift = Path(folder) / "Regression.swift"
    binary = Path(folder) / "regression"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
