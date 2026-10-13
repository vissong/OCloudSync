import XCTest
@testable import SyncCore

final class DateRepairTests: XCTestCase {
  func record(_ state: RecordState = .imported) -> SyncRecord {
    let asset = RemoteAsset(account: "a", remoteID: "r", fileID: "f", filename: "a.mp4",
      bytes: 10, width: 10, height: 10, mediaType: 3, version: "v", isMotion: false)
    var r = SyncRecord(asset: asset, state: state)
    r.photoID = "owned"; r.sha256 = "hash"
    return r
  }
  func testOnlyOwnSuccessfulImportsWithMatchingReceiptAndHash() {
    XCTAssertTrue(DateRepairPolicy.owns(record(), photoID: "owned", hash: "hash"))
    for state: RecordState in [.baseline, .duplicate, .failed, .importing] {
      XCTAssertFalse(DateRepairPolicy.owns(record(state), photoID: "owned", hash: "hash"))
    }
    XCTAssertFalse(DateRepairPolicy.owns(record(), photoID: "other", hash: "hash"))
    XCTAssertFalse(DateRepairPolicy.owns(record(), photoID: "owned", hash: "other"))
    var missing = record(); missing.sha256 = nil
    XCTAssertFalse(DateRepairPolicy.owns(missing, photoID: "owned", hash: nil))
  }
  func testDateGuardsAllowRoundingAndRejectChangesSincePreview() {
    let target = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertTrue(DateRepairPolicy.same(target, target.addingTimeInterval(0.5)))
    XCTAssertFalse(DateRepairPolicy.same(target, target.addingTimeInterval(2)))
    XCTAssertTrue(DateRepairPolicy.same(nil, nil))
    XCTAssertFalse(DateRepairPolicy.same(nil, target))
    XCTAssertTrue(DateRepairPolicy.mayRepair(current: target, previousManaged: nil))
    XCTAssertTrue(DateRepairPolicy.mayRepair(current: target, previousManaged: target))
    XCTAssertFalse(DateRepairPolicy.mayRepair(current: target.addingTimeInterval(3600), previousManaged: target))
  }
}
