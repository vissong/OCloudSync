import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import SyncCore

final class MediaDateTests: XCTestCase {
  func asset(_ millis: Int64? = nil, video: Bool = false) -> RemoteAsset {
    RemoteAsset(account: "a", remoteID: "r", fileID: "f", filename: video ? "a.mp4" : "a.jpg", bytes: 1,
      width: 1, height: 1, mediaType: video ? 3 : 1, version: "v", isMotion: false, dateTakenMilliseconds: millis)
  }
  func testCloudCaptureWinsWithoutOpeningFileForPhotoAndVideo() throws {
    for video in [false, true] {
      let result = try MediaDateResolver.resolve(asset: asset(1_780_000_000_123, video: video), file: URL(fileURLWithPath: "/missing"))
      XCTAssertEqual(result.date.timeIntervalSince1970, 1_780_000_000.123, accuracy: 0.001)
      XCTAssertEqual(result.source, .cloudCapture)
    }
  }
  func testExifOffsetAndStrictDates() {
    let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    let date = MediaDateResolver.exifDate("2026:04:05 11:28:12", offset: "+08:00", timeZone: .gmt)
    XCTAssertEqual(date, MediaDateResolver.exifDate("2026:04:05 03:28:12", offset: "+00:00", timeZone: zone))
    XCTAssertEqual(date, MediaDateResolver.exifDate("2026:04:05 11:28:12", offset: nil, timeZone: zone))
    for bad in ["2026:02:30 03:04:05", "bad", "0000:00:00 00:00:00"] {
      XCTAssertNil(MediaDateResolver.exifDate(bad, offset: nil, timeZone: zone))
    }
    XCTAssertNil(MediaDateResolver.exifDate("2026:04:05 11:28:12", offset: "+99:00", timeZone: zone))
  }
  func testImageCaptureThenOriginalCreationFallbackAndNoDownloadTime() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("original.jpg")
    let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let image = context.makeImage()!
    func write(_ exif: [String: Any]) {
      let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
      CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    write(["DateTimeOriginal": "2020:01:02 03:04:05", "DateTimeDigitized": "2021:01:02 03:04:05"])
    XCTAssertEqual(try MediaDateResolver.resolve(asset: asset(), file: file).source, .imageCapture)
    write(["DateTimeDigitized": "2021:01:02 03:04:05"])
    XCTAssertEqual(try MediaDateResolver.resolve(asset: asset(), file: file).source, .originalCreation)
    write([:])
    XCTAssertThrowsError(try MediaDateResolver.resolve(asset: asset(), file: file))
  }
}
