import XCTest
import AVFoundation
@testable import SyncCore

final class VideoTests: XCTestCase {
  func video(_ id: String = "old", account: String = "u1", ext: String = "MP4") -> RemoteAsset {
    RemoteAsset(account: account, remoteID: id, fileID: "file-" + id, filename: id + "." + ext,
      bytes: 100, width: 1920, height: 1080, mediaType: 3, version: "v1", isMotion: false)
  }
  func testVideoFormatsAndTypes() {
    for ext in ["mp4", "MOV", "m4v"] { XCTAssertTrue(video(ext: ext).supported) }
    XCTAssertFalse(video(ext: "avi").supported)
    var wrongType = video(); wrongType.mediaType = 1
    XCTAssertFalse(wrongType.supported)
    var motion = video(); motion.isMotion = true
    XCTAssertFalse(motion.supported)
  }
  func testUpgradeBuildsVideoBaselineWithoutChangingPhotos() throws {
    var ledger = Ledger()
    var photo = video("photo"); photo.mediaType = 1; photo.filename = "photo.jpg"
    try ledger.mergeScan([photo], account: "u1", complete: true)
    ledger.videoBaselineAccounts = nil // prior release
    let old = video()
    ledger.records[old.key] = SyncRecord(asset: old, state: .unsupported)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let before = try encoder.encode(ledger.records[photo.key])
    ledger.recoverInterrupted()
    XCTAssertEqual(ledger.records[old.key]?.state, .unsupported)
    try ledger.mergeScan([photo, old, video("notPreviouslySeen")], account: "u1", complete: false)
    XCTAssertNil(ledger.videoBaselineAccounts)
    try ledger.mergeScan([photo, old, video("notPreviouslySeen")], account: "u1", complete: true)
    XCTAssertEqual(ledger.videoBaselineAccounts, ["u1"])
    XCTAssertEqual(ledger.records[old.key]?.state, .baseline)
    XCTAssertTrue(ledger.due(at: Date()).isEmpty)
    XCTAssertEqual(try encoder.encode(ledger.records[photo.key]), before)
    ledger = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
    try ledger.mergeScan([photo, old, video("new")], account: "u1", complete: true)
    XCTAssertEqual(ledger.due(at: Date()).map(\.asset.remoteID), ["new"])
  }
  func testVideoBaselineIsAccountScopedAndExistingReceiptIsPreserved() throws {
    var ledger = Ledger(); ledger.accounts.insert("u1")
    let old = video(); var imported = SyncRecord(asset: old, state: .imported)
    imported.photoID = "receipt"; ledger.records[old.key] = imported
    try ledger.mergeScan([old], account: "u1", complete: true)
    XCTAssertEqual(ledger.records[old.key]?.photoID, "receipt")
    XCTAssertEqual(ledger.records[old.key]?.state, .imported)
    try ledger.mergeScan([video(account: "u2")], account: "u2", complete: true)
    XCTAssertEqual(ledger.records[video(account: "u2").key]?.state, .baseline)
    XCTAssertTrue(ledger.due(at: Date()).isEmpty)
  }
  func testOriginalVideoValidationAndCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("original.part.mp4")
    let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
    let created = AVMutableMetadataItem()
    created.identifier = .quickTimeMetadataCreationDate
    created.value = "2020-02-03T04:05:06+08:00" as NSString
    writer.metadata = [created]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 64])
    input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0)
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
    writer.add(input)
    XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    var pixels: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 128, 64, kCVPixelFormatType_32ARGB, nil, &pixels)
    for frame in 0..<15 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
      XCTAssertTrue(adapter.append(pixels!, withPresentationTime: CMTime(value: Int64(frame), timescale: 15)))
    }
    input.markAsFinished(); await writer.finishWriting()
    XCTAssertEqual(writer.status, .completed)
    var original = video(); original.width = 64; original.height = 128
    original.bytes = Int64(try Data(contentsOf: file).count)
    let expected = try RemoteAsset.hashFile(file)
    let actual = try await MediaFileValidator.validate(file, asset: original)
    XCTAssertEqual(actual, expected) // Download staging suffix, rotated dimensions and original bytes
    let resolved = try MediaDateResolver.resolve(asset: original, file: file)
    XCTAssertEqual(resolved.source, .originalCreation)
    XCTAssertEqual(resolved.date, ISO8601DateFormatter().date(from: "2020-02-03T04:05:06+08:00"))
    var wrong = original; wrong.width = 1920
    do { _ = try await MediaFileValidator.validate(file, asset: wrong); XCTFail("wrong dimensions accepted") } catch {}
    wrong = original; wrong.bytes += 1
    do { _ = try await MediaFileValidator.validate(file, asset: wrong); XCTFail("wrong size accepted") } catch {}
    let cancelled = Task { try await MediaFileValidator.validate(file, asset: original) }
    cancelled.cancel()
    do { _ = try await cancelled.value; XCTFail("cancellation ignored") } catch is CancellationError {}
    try Data(repeating: 0, count: Int(original.bytes)).write(to: file)
    do { _ = try await MediaFileValidator.validate(file, asset: original); XCTFail("corrupt video accepted") } catch {}
  }

}
