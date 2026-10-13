import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import SyncCore

final class StaticFallbackTests: XCTestCase {
  func testStaticJPEGPreservesOriginalBytesExifAndIgnoresBrokenMotionTrailer() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("motion.jpg")
    let context = CGContext(data: nil,width: 4,height: 4,bitsPerComponent: 8,bytesPerRow: 16,
      space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let destination = CGImageDestinationCreateWithURL(file as CFURL,UTType.jpeg.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!,
      [kCGImagePropertyExifDictionary: ["DateTimeOriginal": "2026:04:05 11:28:12", "OffsetTimeOriginal": "+08:00"]] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let still = try Data(contentsOf: file)
    var motion = still; motion.append(Data("broken ftypmp42 trailer".utf8))
    try motion.write(to: file)
    let asset = RemoteAsset(account: "a",remoteID: "r",fileID: "f",filename: "motion.jpg",
      bytes: Int64(motion.count),width: 4,height: 4,mediaType: 1,version: "v",isMotion: true)
    let originalHash = RemoteAsset.digest(motion)
    let result = try await StaticPhotoFallback.prepare(file,asset: asset,sourceHash: originalHash,reason: "conversion failed")
    XCTAssertEqual(try Data(contentsOf: result.file), still)
    XCTAssertEqual(result.info.sourceHash, originalHash)
    XCTAssertEqual(result.info.stillHash, RemoteAsset.digest(still))
    XCTAssertEqual(try MediaDateResolver.resolve(asset: asset,file: result.file).date,
      MediaDateResolver.exifDate("2026:04:05 11:28:12",offset: "+08:00",timeZone: .gmt))
    try Data("bad cache".utf8).write(to: result.file)
    let repaired = try await StaticPhotoFallback.prepare(file,asset: asset,sourceHash: originalHash,reason: "conversion failed")
    XCTAssertEqual(try Data(contentsOf: repaired.file),still)
    let task = Task { try await StaticPhotoFallback.prepare(file,asset: asset,sourceHash: originalHash,reason: "cancel") }
    task.cancel()
    do { _ = try await task.value; XCTFail("cancel ignored") } catch is CancellationError {}
  }
  func testEOIInsideMetadataIsNotTheMainImageEndAndTruncationIsRejected() throws {
    let jpeg = Data([0xff,0xd8, 0xff,0xe1,0,6, 0xff,0xd9,0,0, 0xff,0xda,0,2,
      1,2,0xff,0,3,0xff,0xd0,4,0xff,0xd9, 9,9])
    XCTAssertEqual(try StaticPhotoFallback.jpegEnd(in: jpeg),24)
    XCTAssertThrowsError(try StaticPhotoFallback.jpegEnd(in: jpeg.prefix(23)))
    XCTAssertThrowsError(try StaticPhotoFallback.jpegEnd(in: Data("not JPEG".utf8)))
  }
}
