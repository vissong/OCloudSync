import XCTest

@testable import SyncCore

final class MotionTests: XCTestCase {
  func asset(motion: Bool = true, name: String = "test.jpg") -> RemoteAsset {
    RemoteAsset(
      account: "u", remoteID: name, fileID: "f", filename: name, bytes: 80,
      width: 3, height: 4, mediaType: 1, version: "v", isMotion: motion)
  }
  func box(_ name: String, _ bytes: [UInt8]) -> Data {
    let n = UInt32(bytes.count + 8)
    return Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
      + Data(name.utf8) + Data(bytes)
  }
  func testMP4BoundaryAndMalformedInputs() throws {
    let still = Data([0xff, 0xd8, 0xff, 0xd9])
    let movie =
      box("ftyp", Array("mp42".utf8) + [0, 0, 0, 0] + Array("mp42".utf8))
      + box("moov", []) + box("mdat", [1, 2, 3])
    XCTAssertEqual(try MotionJPEG.inspect(still + movie).videoOffset, still.count)
    XCTAssertThrowsError(try MotionJPEG.inspect(still))
    XCTAssertThrowsError(try MotionJPEG.inspect(Data("ftypmp42".utf8) + movie))
    XCTAssertThrowsError(try MotionJPEG.inspect(still + movie.dropLast()))
  }
  func testSourceTimingAndFallbackAreExplicit() throws {
    XCTAssertEqual(try MotionJPEG.stillTime(microseconds: 850000, duration: 2).seconds, 0.85)
    XCTAssertFalse(try MotionJPEG.stillTime(microseconds: 850000, duration: 2).usedFallback)
    XCTAssertEqual(try MotionJPEG.stillTime(microseconds: nil, duration: 2).seconds, 1)
    XCTAssertTrue(try MotionJPEG.stillTime(microseconds: -1, duration: 2).usedFallback)
    XCTAssertThrowsError(try MotionJPEG.stillTime(microseconds: 2_000_000, duration: 2))
    XCTAssertThrowsError(try MotionJPEG.stillTime(microseconds: nil, duration: .nan))
  }
  func testXMPPresentationTimeIsRead() throws {
    let xmp = Data("<rdf:Description GCamera:MotionPhotoPresentationTimestampUs=\"1299119\"/>".utf8)
    XCTAssertEqual(try MotionJPEG.presentationTimestamp(in: xmp), 1_299_119)
    XCTAssertThrowsError(
      try MotionJPEG.presentationTimestamp(
        in: Data(
          "<x GCamera:MotionPhotoPresentationTimestampUs=\"bad\"/>".utf8)))
  }
  func testStableContentIdentifierAndEligibility() {
    let a = String(repeating: "a", count: 64)
    let b = String(repeating: "b", count: 64)
    XCTAssertEqual(
      LivePhotoManifest.identifier(sourceHash: a), LivePhotoManifest.identifier(sourceHash: a))
    XCTAssertNotEqual(
      LivePhotoManifest.identifier(sourceHash: a), LivePhotoManifest.identifier(sourceHash: b))
    XCTAssertTrue(asset().supported)
    XCTAssertFalse(asset(name: "test.heic").supported)
    XCTAssertTrue(asset(motion: false, name: "test.heic").supported)
  }
  func testUpgradeRequeuesOnlyNewUnsupportedMotionJPEG() throws {
    var ledger = Ledger()
    let old = asset(name: "old.jpg")
    let newer = asset()
    let unsupported = asset(name: "test.heic")
    ledger.records[old.key] = SyncRecord(asset: old, state: .baseline)
    ledger.records[newer.key] = SyncRecord(asset: newer, state: .unsupported)
    ledger.records[unsupported.key] = SyncRecord(asset: unsupported, state: .unsupported)
    ledger.recoverInterrupted()
    XCTAssertEqual(ledger.records[old.key]?.state, .baseline)
    XCTAssertEqual(ledger.records[newer.key]?.state, .pending)
    XCTAssertEqual(ledger.records[unsupported.key]?.state, .unsupported)
    let restored = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
    XCTAssertEqual(restored.due(at: Date()).count, 1)
  }
  func testConfirmedNoImportCanRetryWhileUncertainImportIsPreserved() {
    var confirmed = SyncRecord(asset: asset(), state: .importing)
    confirmed.fail("permission or missing pair", importWasNotCommitted: true)
    XCTAssertEqual(confirmed.state, .failed)
    XCTAssertNotNil(confirmed.nextAttempt)
    var uncertain = SyncRecord(asset: asset(), state: .importing)
    uncertain.fail("verification interrupted")
    XCTAssertEqual(uncertain.state, .importing)
  }
  func testGPSRetainsCoordinatesButAllowsUnsupportedProcessingMethod() throws {
    let source: [String: Any] = [
      "Latitude": 1.25, "LatitudeRef": "N", "Longitude": 2.5,
      "LongitudeRef": "E", "Altitude": 10, "ProcessingMethod": "CELLID",
    ]
    var converted = source
    converted.removeValue(forKey: "ProcessingMethod")
    XCTAssertNoThrow(try StillMetadata.validateGPS(source, converted))
    converted["Latitude"] = 1.2501
    XCTAssertThrowsError(try StillMetadata.validateGPS(source, converted))
    converted = source
    converted.removeValue(forKey: "LongitudeRef")
    XCTAssertThrowsError(try StillMetadata.validateGPS(source, converted))
    XCTAssertThrowsError(try StillMetadata.validateGPS(source, nil))
  }
  func testWorkerCancellationAndTimeoutRemoveStageAfterExit() async throws {
    // Repeat both stop paths: termination delivery can race task resumption on another thread.
    for cancel in [true, false, true, false, true, false] {
      let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
      try Data([1, 2]).write(to: stage.appendingPathComponent("motion.mp4"))
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sleep")
      process.arguments = ["10"]
      let task = Task {
        try await ConversionWorker.run(process, stage: stage, timeout: cancel ? 10 : 0.1)
      }
      try await Task.sleep(nanoseconds: 200_000_000)
      if cancel { task.cancel() }
      do {
        try await task.value
        XCTFail("Expected interruption")
      } catch {}
      XCTAssertFalse(process.isRunning)
      XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }
  }

  func testConfirmedFailureIsRetainedEvenWhenTaskIsCancelled() async {
    let pending = asset()
    let task = Task { () -> SyncRecord in
      withUnsafeCurrentTask { $0?.cancel() }
      var record = SyncRecord(asset: pending, state: .importing)
      record.fail("Photos confirmed failure during stop", importWasNotCommitted: true)
      XCTAssertTrue(Task.isCancelled)
      return record
    }
    let record = await task.value
    XCTAssertEqual(record.state, .failed)
    XCTAssertNotNil(record.nextAttempt)
  }

  func testAllXMPTimeValuesMustBeValidAndConsistent() throws {
    for value in ["bad", "9223372036854775808", "850001"] {
      let xmp =
        "<x MotionPhotoPresentationTimestampUs=\"850000\" MicroVideoPresentationTimestampUs=\"\(value)\"/>"
      XCTAssertThrowsError(try MotionJPEG.presentationTimestamp(in: Data(xmp.utf8)))
    }
    XCTAssertThrowsError(
      try MotionJPEG.presentationTimestamp(
        in: Data("<x MotionPhotoPresentationTimestampUs=\"9223372036854775808\"/>".utf8)))
    XCTAssertEqual(
      try MotionJPEG.presentationTimestamp(
        in: Data(
          "<x MotionPhotoPresentationTimestampUs=\"850000\" MicroVideoPresentationTimestampUs=\"850000\"/>"
            .utf8)), 850000)
  }

}
