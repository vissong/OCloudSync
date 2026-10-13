import XCTest
@testable import SyncCore

final class QueueTests: XCTestCase {
  func asset(_ id: String) -> RemoteAsset {
    RemoteAsset(account: "a", remoteID: id, fileID: id, filename: id + ".jpg", bytes: 10,
      width: 2, height: 2, mediaType: 1, version: "v1", isMotion: false,
      dateTakenMilliseconds: 1_800_000_000_000)
  }
  func testLegacyQueueMigrationKeepsOnlyUnfinishedWorkAndIsIdempotent() throws {
    var ledger = Ledger()
    let states: [RecordState] = [.baseline, .pending, .downloaded, .failed, .importing, .imported, .duplicate, .unavailable]
    for (n,state) in states.enumerated() {
      let a = asset(String(n)); ledger.records[a.key] = SyncRecord(asset: a,state: state)
    }
    let oldData = try JSONEncoder().encode(ledger)
    var restored = try JSONDecoder().decode(Ledger.self, from: oldData)
    restored.migrateImportQueue()
    XCTAssertEqual(restored.importBatches?.count, 1)
    XCTAssertEqual(restored.importBatches?.first?.source, .legacy)
    XCTAssertEqual(restored.importBatches?.first?.recordKeys.count, 5)
    let batch = restored.importBatches!.first!
    restored.migrateImportQueue()
    XCTAssertEqual(restored.importBatches?.first?.id, batch.id)
    XCTAssertEqual(restored.records.count, 8)
  }
  func testRangeBatchPersistsSelectionAndProgressAcrossRestart() throws {
    let a = asset("one"), b = asset("two"), now = a.captureDate!
    let scan = ScanResult(account: "a", assets: [a,b], headKeys: [a.key,b.key],
      summary: ScanSummary(complete: true,scanned: 2,total: 2,listRequests: 1,seconds: 0,checkedAt: now,reason: "test"))
    let range = try ImportDateRange(startDay: now,endDay: now,timeZone: .gmt)
    let preview = try DateRangePreview(scan: scan,range: range,includePhotos: true,includeVideos: true)
    var ledger = Ledger()
    _ = try ledger.queueRangeImport(preview,selectedKeys: [a.key,b.key],freshScan: scan,now: now)
    let batch = try XCTUnwrap(ledger.importBatches?.first)
    XCTAssertEqual(Set(batch.recordKeys), [a.key,b.key])
    XCTAssertEqual(batch.range, range)
    ledger.records[a.key]?.state = .imported
    ledger.records[b.key]?.state = .failed
    let restored = try JSONDecoder().decode(Ledger.self,from: JSONEncoder().encode(ledger))
    let summary = restored.queueSummary(keys: batch.recordKeys)
    XCTAssertEqual(summary.total, 2); XCTAssertEqual(summary.imported, 1)
    XCTAssertEqual(summary.failed, 1); XCTAssertEqual(summary.successful, 1)
    XCTAssertEqual(summary.remaining, 1)
    XCTAssertEqual(restored.queueRecords(batchID: batch.id).count, 2)
    XCTAssertEqual(restored.importBatches?.first?.id, batch.id)
    let encoded = try JSONEncoder().encode(restored)
    ledger = restored
    XCTAssertThrowsError(try ledger.queueRangeImport(preview,selectedKeys: [a.key],freshScan: scan,now: now))
    XCTAssertEqual(try JSONDecoder().decode(Ledger.self,from: encoded).importBatches?.count, ledger.importBatches?.count)
  }
  func testAutomaticBatchExcludesBaselineAndDoesNotDuplicateOnRescan() throws {
    let a = asset("old"), b = asset("new")
    var ledger = Ledger(); ledger.migrateImportQueue()
    try ledger.mergeScan([a],account: "a",complete: true)
    XCTAssertTrue(ledger.importBatches?.isEmpty == true)
    try ledger.mergeScan([a,b],account: "a",complete: true)
    XCTAssertEqual(ledger.importBatches?.count, 1)
    XCTAssertEqual(ledger.importBatches?.first?.recordKeys, [b.key])
    XCTAssertEqual(ledger.importBatches?.first?.source, .automatic)
    try ledger.mergeScan([a,b],account: "a",complete: true)
    XCTAssertEqual(ledger.importBatches?.count, 1)
  }
  func testActiveConversionCountsAsProcessingAndOldConversionFailuresRequeueOnlyOnce() throws {
    var ledger = Ledger()
    var motion = asset("motion"); motion.isMotion = true
    var failed = SyncRecord(asset: motion,state: .failed)
    failed.attempts = 6; failed.error = "实况转换失败，未导入静态图：invalid video"
    ledger.records[failed.id] = failed
    var uncertain = failed; uncertain.asset.remoteID = "uncertain"; uncertain.state = .importing
    ledger.records[uncertain.id] = uncertain
    ledger.migrateStaticFallback()
    XCTAssertEqual(ledger.records[failed.id]?.state, .pending)
    XCTAssertEqual(ledger.records[failed.id]?.attempts, 0)
    XCTAssertEqual(ledger.records[uncertain.id]?.state, .importing)
    ledger.records[failed.id] = failed
    ledger.migrateStaticFallback()
    XCTAssertEqual(ledger.records[failed.id]?.state, .failed)
    var converted = SyncRecord(asset: asset("conversion"),state: .downloaded)
    let summary = QueueSummary(records: [converted],activeKey: converted.id)
    XCTAssertEqual(summary.active, 1); XCTAssertEqual(summary.waiting, 0)
    converted.state = .imported
    XCTAssertEqual(QueueSummary(records: [converted],activeKey: converted.id).successful, 1)
  }
}
