import XCTest
@testable import SyncCore

final class FilenameDateTests: XCTestCase {
  func asset(video: Bool = false, motion: Bool = false) -> RemoteAsset {
    RemoteAsset(account: "a",remoteID: "r",fileID: "f",filename: video ? "IMG.MP4" : "IMG.JPG",
      bytes: 10,width: 2,height: 2,mediaType: video ? 3 : 1,version: "v",isMotion: motion)
  }
  func testFilenameDateAndMediaTypeMustAllMatch() {
    let date = Date(timeIntervalSince1970: 1_800_000_000.123)
    func match(_ name: String, _ other: Date?, video: Bool = false) -> Bool {
      FilenameDateMatch.matches(asset: asset(), date: date, filename: name, creationDate: other,
        isVideo: video, isLivePhoto: false)
    }
    XCTAssertTrue(match("img.jpg", date))
    XCTAssertTrue(match("IMG.JPG", date.addingTimeInterval(0.7)))
    XCTAssertFalse(match("OTHER.JPG", date))
    XCTAssertFalse(match("IMG.JPG", date.addingTimeInterval(1)))
    XCTAssertFalse(match("IMG.JPG", nil))
    XCTAssertFalse(match("IMG.JPG", date,video: true))
  }
  func testConvertedLivePhotoUsesItsActualFilenameOnlyForLiveCandidates() {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    XCTAssertTrue(FilenameDateMatch.matches(asset: asset(motion: true),date: date,
      filename: "IMG.heic",creationDate: date,isVideo: false,isLivePhoto: true))
    XCTAssertFalse(FilenameDateMatch.matches(asset: asset(motion: true),date: date,
      filename: "IMG.heic",creationDate: date,isVideo: false,isLivePhoto: false))
    XCTAssertFalse(FilenameDateMatch.matches(asset: asset(),date: date,
      filename: "IMG.heic",creationDate: date,isVideo: false,isLivePhoto: true))
  }
}
