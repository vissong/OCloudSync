import AVFoundation
import XCTest
@testable import SyncCore

final class VideoCompatibilityTests: XCTestCase {
  func testHEVCCompatibilityPreservesOriginalDateAndMediaBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("source.mp4")
    try await makeMovie(file, codec: .hevc)
    var data = try Data(contentsOf: file)
    // Only change the generated sample entry, not arbitrary media payload bytes.
    let marker = try sampleEntryTag(file)
    data.replaceSubrange(marker, with: Data("hev1".utf8))
    try data.write(to: file)
    var asset = remote(bytes: data.count)
    let originalHash = try RemoteAsset.hashFile(file)
    let beforeDate = try MediaDateResolver.resolve(asset: asset, file: file)
    let prepared = try await VideoCompatibility.prepare(file, asset: asset, sourceHash: originalHash)
    XCTAssertNotEqual(prepared.file, file)
    let info = try XCTUnwrap(prepared.info)
    XCTAssertEqual(info.sourceHash, originalHash)
    XCTAssertEqual(info.importHash, prepared.hash)
    XCTAssertEqual(try Data(contentsOf: file), data)
    XCTAssertEqual(try RemoteAsset.hashFile(prepared.file), info.importHash)
    XCTAssertEqual(try MediaDateResolver.resolve(asset: asset, file: prepared.file), beforeDate)
    let validated = try await MediaFileValidator.validate(prepared.file, asset: asset)
    XCTAssertEqual(validated, prepared.hash)
    let output = try Data(contentsOf: prepared.file)
    XCTAssertEqual(output.count, data.count)
    // This fixture has complete configuration arrays; only its codec tag needs changing.
    data.replaceSubrange(marker, with: Data("hvc1".utf8))
    XCTAssertEqual(output, data)
    let again = try await VideoCompatibility.prepare(file, asset: asset, sourceHash: originalHash)
    XCTAssertEqual(again.hash, prepared.hash)
    XCTAssertEqual(again.file, prepared.file)
    asset.width += 1
    do { _ = try await VideoCompatibility.prepare(file, asset: asset, sourceHash: originalHash)
      XCTFail("wrong dimensions accepted") } catch {}
    do { _ = try await VideoCompatibility.prepare(file, asset: remote(bytes: data.count), sourceHash: "wrong")
      XCTFail("wrong source hash accepted") } catch {}
    let task = Task { try await VideoCompatibility.prepare(file, asset: self.remote(bytes: data.count), sourceHash: originalHash) }
    task.cancel()
    do { _ = try await task.value; XCTFail("cancellation ignored") } catch is CancellationError {}
    var record = SyncRecord(asset: remote(bytes: data.count), state: .imported)
    record.sha256 = originalHash; record.videoCompatibility = info
    XCTAssertEqual(record.resultLabel, "视频已兼容导入")
    let restored = try JSONDecoder().decode(SyncRecord.self, from: JSONEncoder().encode(record))
    XCTAssertEqual(restored.videoCompatibility, info)
  }

  func testPlayableVideoStaysUnchangedAndMalformedFileFails() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("source.mp4")
    try await makeMovie(file, codec: .h264)
    let data = try Data(contentsOf: file), hash = try RemoteAsset.hashFile(file)
    let prepared = try await VideoCompatibility.prepare(file, asset: remote(bytes: data.count), sourceHash: hash)
    XCTAssertNil(prepared.info); XCTAssertEqual(prepared.file, file); XCTAssertEqual(prepared.hash, hash)
    try Data(repeating: 0, count: data.count).write(to: file)
    do { _ = try await VideoCompatibility.prepare(file, asset: remote(bytes: data.count), sourceHash: RemoteAsset.hashFile(file))
      XCTFail("corrupt video accepted") } catch {}
  }

  func testRejectsInBandParameterSetsAndInvalidNALLengths() throws {
    XCTAssertNoThrow(try HEVCCompatibility.checkSample(Data([0,0,0,3,2,1,0]), lengthBytes: 4))
    for type in [32,33,34] {
      XCTAssertThrowsError(try HEVCCompatibility.checkSample(Data([0,0,0,2,UInt8(type << 1),1]), lengthBytes: 4))
      XCTAssertNoThrow(try HEVCCompatibility.checkSample(Data([0,0,0,2,UInt8(type << 1),1]), lengthBytes: 4,
        parameterSets: [Data([UInt8(type << 1),1])]))
      XCTAssertThrowsError(try HEVCCompatibility.checkSample(Data([0,0,0,3,UInt8(type << 1),1,9]), lengthBytes: 4,
        parameterSets: [Data([UInt8(type << 1),1,8])]))
    }
    for data in [Data([0,0,0,9,2,1]),Data([0,0,0,0]),Data([0,0,0]),Data([0,0,0,1,2])] {
      XCTAssertThrowsError(try HEVCCompatibility.checkSample(data, lengthBytes: 4))
    }
  }

  func testFragmentedHEVCAndMalformedConfiguration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("fragments.mp4")
    try await makeMovie(file, codec: .hevc, fragmented: true)
    var data = try Data(contentsOf: file)
    XCTAssertNotNil(data.range(of: Data("moof".utf8)))
    let tag = try sampleEntryTag(file)
    data.replaceSubrange(tag, with: Data("hev1".utf8))
    try data.write(to: file)
    let plan = try HEVCCompatibility.plan(file)
    XCTAssertEqual(plan.parameterSets.count, 3)
    let prepared = try await VideoCompatibility.prepare(file, asset: remote(bytes: data.count))
    XCTAssertNotNil(prepared.info)
    XCTAssertEqual(try Data(contentsOf: file), data)
    let config = try XCTUnwrap(data.range(of: Data("hvcC".utf8), in: tag.upperBound..<data.count))
    var damaged = data
    damaged[config.upperBound + 22] = 255 // impossible array count
    try damaged.write(to: file)
    XCTAssertThrowsError(try HEVCCompatibility.plan(file))
    try data.dropLast(4).write(to: file)
    XCTAssertThrowsError(try HEVCCompatibility.plan(file))
    damaged = data
    damaged.replaceSubrange(0..<4, with: Data([0xff,0xff,0xff,0xff]))
    try damaged.write(to: file)
    XCTAssertThrowsError(try HEVCCompatibility.plan(file))
  }

  private func remote(bytes: Int) -> RemoteAsset {
    RemoteAsset(account: "test", remoteID: "video", fileID: "file", filename: "original.mp4",
      bytes: Int64(bytes), width: 128, height: 64, mediaType: 3, version: "v1", isMotion: false)
  }
  private func sampleEntryTag(_ file: URL) throws -> Range<Int> {
    let plan = try HEVCCompatibility.plan(file, entryType: "hvc1")
    let tag = try XCTUnwrap(plan.patches.first)
    return tag.offset..<(tag.offset + 4)
  }
  private func makeMovie(_ file: URL, codec: AVVideoCodecType, fragmented: Bool = false) async throws {
    let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
    if fragmented { writer.movieFragmentInterval = CMTime(value: 1, timescale: 3) }
    let date = AVMutableMetadataItem(); date.identifier = .quickTimeMetadataCreationDate
    date.value = "2020-02-03T04:05:06+08:00" as NSString; writer.metadata = [date]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: codec, AVVideoWidthKey: 128, AVVideoHeightKey: 64])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
      sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
    writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    var pixels: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 128, 64, kCVPixelFormatType_32ARGB, nil, &pixels)
    for frame in 0..<15 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
      XCTAssertTrue(adapter.append(pixels!, withPresentationTime: CMTime(value: Int64(frame), timescale: 15)))
    }
    input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
  }
}
