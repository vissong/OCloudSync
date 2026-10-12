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
struct ConfirmedImportFailure: Error { init(_ message: String) {} }
struct RemoteAsset { let key: String; let filename: String; let isVideo: Bool }
enum ResourceType { case photo, video }
final class PHAssetResourceCreationOptions { var originalFilename = "" }
struct Placeholder { let localIdentifier = "synthetic-receipt" }
final class PHAssetCreationRequest {
  static var resources = [ResourceType]()
  static var filename = ""
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
  struct Receipt: Codable { let photoID: String; var sourceHash: String? }
  let journalDirectory: URL
  var allowed = true
  var validationHash = "hash"
  var verificationFails = false
  var verified = false
  init(_ directory: URL) { journalDirectory = directory }
  func checkPermission() throws { if !allowed { throw SyncFailure("denied") } }
  func validate(_ file: URL, asset: RemoteAsset) async throws -> String { validationHash }
  func verifyOriginalVideo(_ id: String, hash: String) async throws {
    verified = true
    if verificationFails { throw SyncFailure("uncertain verification") }
  }
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
    guard PHAssetCreationRequest.resources == [.video], spy.verified,
      PHAssetCreationRequest.filename == "original.mp4" else { fatalError("wrong import resource") }
    let receipt = try JSONDecoder().decode(ImportSpy.Receipt.self, from: Data(contentsOf: journal))
    guard receipt.sourceHash == "hash" else { fatalError("missing original hash") }
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
    print("PASS: video/photo resource type, original receipt, confirmed rejection, uncertain verification, preflight guards")
  }
}
'''.replace("__METHOD__", extract("  func importFile("))
with tempfile.TemporaryDirectory(prefix="ocloud-video-import-") as folder:
    swift = Path(folder) / "Regression.swift"
    binary = Path(folder) / "regression"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
