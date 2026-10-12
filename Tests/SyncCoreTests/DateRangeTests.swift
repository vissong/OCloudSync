import XCTest
@testable import SyncCore

final class DateRangeTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
  func range(_ start: String = "2026-10-01T08:00:00Z", _ end: String = "2026-10-02T08:00:00Z", zone: String = "Asia/Shanghai") throws -> ImportDateRange {
    try ImportDateRange(startDay: date(start), endDay: date(end), timeZone: TimeZone(identifier: zone)!)
  }
  func asset(_ id: String, when: String? = "2026-10-01T04:00:00Z", video: Bool = false, account: String = "a") -> RemoteAsset {
    RemoteAsset(account: account, remoteID: id, fileID: id, filename: id + (video ? ".MP4" : ".JPG"),
      bytes: 123, width: 10, height: 20, mediaType: video ? 3 : 1, version: "v1", isMotion: false,
      dateTakenMilliseconds: when.map { Int64(date($0).timeIntervalSince1970 * 1000) })
  }
  func scan(_ assets: [RemoteAsset], complete: Bool = true) -> ScanResult {
    ScanResult(account: assets.first?.account ?? "a", assets: assets, headKeys: assets.map(\.key),
      summary: ScanSummary(complete: complete, scanned: assets.count, total: assets.count,
        listRequests: 1, seconds: 0, checkedAt: now, reason: "test"))
  }
  func preview(_ assets: [RemoteAsset], photos: Bool = true, videos: Bool = true) throws -> DateRangePreview {
    try DateRangePreview(scan: scan(assets), range: range(), includePhotos: photos, includeVideos: videos)
  }
  func testInclusiveCalendarDaysAndDST() throws {
    let r = try range()
    XCTAssertEqual(r.start, date("2026-09-30T16:00:00Z"))
    XCTAssertEqual(r.endExclusive, date("2026-10-02T16:00:00Z"))
    XCTAssertTrue(r.contains(asset("start", when: "2026-09-30T16:00:00Z")))
    XCTAssertTrue(r.contains(asset("end", when: "2026-10-02T15:59:59Z")))
    XCTAssertFalse(r.contains(asset("next", when: "2026-10-02T16:00:00Z")))
    let dst = try range("2026-03-08T12:00:00Z", "2026-03-08T12:00:00Z", zone: "America/Los_Angeles")
    XCTAssertEqual(dst.endExclusive.timeIntervalSince(dst.start), 23 * 3600)
    XCTAssertThrowsError(try range("2026-10-03T08:00:00Z", "2026-10-01T08:00:00Z"))
  }
  func testDateMetadataDoesNotChangeIdentityAndOldLedgerStillDecodes() throws {
    let a = asset("a"); var noDate = a; noDate.dateTakenMilliseconds = nil
    XCTAssertEqual(a.key, noDate.key)
    let decoded = try JSONDecoder().decode(RemoteAsset.self, from: JSONEncoder().encode(noDate))
    XCTAssertNil(decoded.captureDate)
    var invalid = a; invalid.dateTakenMilliseconds = -1
    XCTAssertNil(invalid.captureDate)
    invalid.dateTakenMilliseconds = Int64.max
    XCTAssertNil(invalid.captureDate)
  }
  func testPreviewTypesMissingDatesAndInvalidInventory() throws {
    let photo = asset("p"), video = asset("v", video: true), missing = asset("missing", when: nil)
    let p = try preview([photo, video, missing, asset("outside", when: "2026-01-01T00:00:00Z")])
    XCTAssertEqual(Set(p.items.map(\.key)), [photo.key, video.key])
    XCTAssertEqual(p.missingDateCount, 1)
    XCTAssertEqual(try preview([photo, video], photos: false).items.map(\.key), [video.key])
    XCTAssertEqual(try preview([photo, video], videos: false).items.map(\.key), [photo.key])
    XCTAssertThrowsError(try preview([photo], photos: false, videos: false))
    XCTAssertThrowsError(try DateRangePreview(scan: scan([photo], complete: false), range: range(), includePhotos: true, includeVideos: true))
    XCTAssertThrowsError(try preview([photo, asset("other", account: "b")]))
  }
  func testQueueOnlySelectedHistoricalRecordsAndNoAutomaticBaselineChanges() throws {
    let a = asset("selected"), b = asset("unselected", video: true)
    var l = Ledger(); try l.mergeScan([a,b], account: "a", complete: true)
    let encode = JSONEncoder(); encode.outputFormatting = [.sortedKeys]
    let before = try encode.encode(l.records[b.key])
    let p = try preview([a,b]); XCTAssertEqual(p.eligibleKeys(in: l), [a.key,b.key])
    let keys = try l.queueRangeImport(p, selectedKeys: [a.key], freshScan: scan([a,b]), now: now)
    XCTAssertEqual(keys, [a.key]); XCTAssertEqual(l.records[a.key]?.state, .pending)
    XCTAssertEqual(try encode.encode(l.records[b.key]), before)
    XCTAssertEqual(l.accounts, ["a"]); XCTAssertEqual(l.videoBaselineAccounts, ["a"])
    var clean = Ledger()
    _ = try clean.queueRangeImport(p, selectedKeys: [a.key], freshScan: scan([a,b]), now: now)
    XCTAssertNil(clean.records[b.key]); XCTAssertTrue(clean.accounts.isEmpty)
    XCTAssertNil(clean.videoBaselineAccounts); XCTAssertNil(clean.lastScan)
    let restored = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(clean))
    XCTAssertEqual(restored.due(at: now).map(\.id), [a.key])
  }
  func testAlreadyImportedDuplicateAndUncertainTransactionsCannotBeRequeued() throws {
    let all = [asset("done"),asset("dup"),asset("uncertain"),asset("pending"),asset("failure")]
    var l = Ledger()
    for (a,state) in zip(all,[RecordState.imported,.duplicate,.importing,.pending,.failed]) {
      var r = SyncRecord(asset: a,state: state); r.photoID = "receipt"; r.sha256 = "hash"
      r.attempts = 6; l.records[a.key] = r
    }
    let p = try preview(all)
    XCTAssertEqual(p.eligibleKeys(in: l), [all[4].key])
    for a in all.prefix(4) { XCTAssertThrowsError(try l.queueRangeImport(p, selectedKeys: [a.key], freshScan: scan(all), now: now)) }
    _ = try l.queueRangeImport(p, selectedKeys: [all[4].key], freshScan: scan(all), now: now)
    XCTAssertEqual(l.records[all[4].key]?.photoID,"receipt")
    XCTAssertEqual(l.records[all[4].key]?.sha256,"hash")
    XCTAssertEqual(l.records[all[4].key]?.attempts,0)
  }
  func testStaleChangedAccountMissingVersionAndOutsideSelectionAreAtomicFailures() throws {
    let a = asset("a"), b = asset("b")
    let p = try preview([a,b]); var l = Ledger()
    XCTAssertThrowsError(try l.queueRangeImport(p, selectedKeys: [a.key], freshScan: scan([a,b]), now: now.addingTimeInterval(1801)))
    XCTAssertThrowsError(try l.queueRangeImport(p, selectedKeys: [a.key], freshScan: scan([asset("a",account:"other")]), now: now))
    XCTAssertThrowsError(try l.queueRangeImport(p, selectedKeys: [a.key,b.key], freshScan: scan([a]), now: now))
    XCTAssertTrue(l.records.isEmpty)
    XCTAssertThrowsError(try l.queueRangeImport(p, selectedKeys: [asset("outside").key], freshScan: scan([a,b]), now: now))
    var changed = a; changed.dateTakenMilliseconds = Int64(date("2026-12-01T00:00:00Z").timeIntervalSince1970*1000)
    XCTAssertThrowsError(try l.queueRangeImport(p, selectedKeys: [a.key], freshScan: scan([changed,b]), now: now))
    XCTAssertThrowsError(try l.queueRangeImport(p, selectedKeys: [], freshScan: scan([a,b]), now: now))
    XCTAssertTrue(l.records.isEmpty)
  }
  func testUnsupportedFilesAreVisibleButCannotBeQueued() throws {
    var a = asset("raw"); a.filename = "raw.dng"
    let p = try preview([a]); XCTAssertEqual(p.items.count,1)
    XCTAssertTrue(p.eligibleKeys(in: Ledger()).isEmpty)
    var l = Ledger()
    XCTAssertThrowsError(try l.queueRangeImport(p, selectedKeys: [a.key], freshScan: scan([a]), now: now))
  }
}
