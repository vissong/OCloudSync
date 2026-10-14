import XCTest
@testable import SyncCore

final class CleanupTests: XCTestCase {
  func asset(_ id: String) -> RemoteAsset {
    RemoteAsset(account: "account",remoteID: id,fileID: id,filename: id + ".jpg",
      bytes: 10,width: 2,height: 2,mediaType: 1,version: "v1",isMotion: false,
      dateTakenMilliseconds: 1_800_000_000_000)
  }
  func testClearQueuePersistsAndDoesNotReactivateOnScanRetryOrRestart() throws {
    var ledger = Ledger()
    let states: [RecordState] = [.baseline,.imported,.duplicate,.pending,.failed,.importing,.unavailable]
    let assets = states.indices.map { asset(String($0)) }
    try ledger.mergeScan(assets,account: "account",complete: true)
    for (index,state) in states.enumerated() {
      var record = SyncRecord(asset: assets[index],state: state)
      record.sha256 = "hash"; record.photoID = "photo"; record.error = "old failure"
      record.nextAttempt = .distantPast
      ledger.records[record.id] = record
    }
    ledger.importBatches = [ImportBatch(source: .dateRange,keys: assets.dropFirst().map(\.key))]
    let completed = ledger.records[assets[1].key]!
    ledger.clearImportQueue()
    XCTAssertTrue(ledger.queueRecords().isEmpty)
    XCTAssertTrue(ledger.due(at: .distantFuture).isEmpty)
    XCTAssertNil(ledger.records[assets[0].key]?.queueCancelledAt)
    XCTAssertNil(ledger.records[assets[1].key]?.queueCancelledAt)
    XCTAssertEqual(ledger.records[assets[1].key]?.photoID, completed.photoID)
    XCTAssertEqual(ledger.records[assets[5].key]?.state,.importing)
    XCTAssertEqual(ledger.records[assets[5].key]?.sha256,"hash")
    XCTAssertEqual(ledger.records[assets[3].key]?.resultLabel,"已取消")
    ledger = try JSONDecoder().decode(Ledger.self,from: JSONEncoder().encode(ledger))
    ledger.recoverInterrupted(); ledger.migrateImportQueue(); ledger.retryFailures()
    try ledger.mergeScan(assets,account: "account",complete: true)
    XCTAssertTrue(ledger.due(at: .distantFuture).isEmpty)
    XCTAssertTrue(ledger.queueRecords().isEmpty)
    XCTAssertEqual(ledger.records.count,assets.count)
    XCTAssertEqual(ledger.accounts,["account"])
    let now = assets[0].captureDate!
    let scan = ScanResult(account: "account",assets: assets,headKeys: assets.map(\.key),
      summary: ScanSummary(complete: true,scanned: assets.count,total: assets.count,listRequests: 1,seconds: 0,checkedAt: now,reason: "test"))
    let preview = try DateRangePreview(scan: scan,range: ImportDateRange(startDay: now,endDay: now),includePhotos: true,includeVideos: true)
    XCTAssertEqual(preview.eligibility(assets[1],in: ledger),.completed)
    XCTAssertEqual(preview.eligibility(assets[5],in: ledger),.ready)
    _ = try ledger.queueRangeImport(preview,selectedKeys: [assets[3].key,assets[5].key],freshScan: scan,now: now)
    XCTAssertNil(ledger.records[assets[3].key]?.queueCancelledAt)
    XCTAssertEqual(ledger.records[assets[3].key]?.state,.pending)
    XCTAssertEqual(ledger.records[assets[5].key]?.state,.importing)
    XCTAssertEqual(ledger.due(at: now).count,2)
  }
  func testCacheStatisticsAndClearStayInsideOriginals() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let originals = root.appendingPathComponent("originals"), outside = root.appendingPathComponent("imports")
    try FileManager.default.createDirectory(at: originals.appendingPathComponent("live/nested"),withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside,withIntermediateDirectories: true)
    try Data(repeating: 1,count: 10).write(to: originals.appendingPathComponent("original.jpg"))
    try Data(repeating: 2,count: 20).write(to: originals.appendingPathComponent("live/nested/pair.mov"))
    try Data(repeating: 3,count: 30).write(to: originals.appendingPathComponent(".partial.mp4"))
    let receipt = outside.appendingPathComponent("receipt.json")
    try Data("keep".utf8).write(to: receipt)
    try FileManager.default.createSymbolicLink(at: originals.appendingPathComponent("outside-link"),withDestinationURL: outside)
    let before = try OriginalCache.measure(originals)
    XCTAssertEqual(before.fileCount,3); XCTAssertEqual(before.logicalBytes,60)
    XCTAssertGreaterThanOrEqual(before.allocatedBytes,0)
    let result = try OriginalCache.clear(originals)
    XCTAssertEqual(result.failedEntries,0)
    XCTAssertEqual(result.remaining.fileCount,0); XCTAssertEqual(result.remaining.logicalBytes,0)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: originals.path).isEmpty)
    XCTAssertEqual(try String(contentsOf: receipt),"keep")
    XCTAssertEqual(try OriginalCache.clear(originals).remaining.fileCount,0)
    let link = root.appendingPathComponent("linked-root")
    try FileManager.default.createSymbolicLink(at: link,withDestinationURL: outside)
    XCTAssertThrowsError(try OriginalCache.clear(link))
    XCTAssertThrowsError(try OriginalCache.measure(link))
    XCTAssertEqual(try String(contentsOf: receipt),"keep")
  }
  func testPartialCleanupReportsFailureAndRemainingBytes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0,count: 20).write(to: root.appendingPathComponent("locked"))
    try Data(repeating: 0,count: 30).write(to: root.appendingPathComponent("removable"))
    let result = try OriginalCache.clear(root) { url in
      if url.lastPathComponent == "locked" { throw CocoaError(.fileWriteNoPermission) }
      try FileManager.default.removeItem(at: url)
    }
    XCTAssertEqual(result.failedEntries,1)
    XCTAssertEqual(result.remaining.fileCount,1)
    XCTAssertEqual(result.remaining.logicalBytes,20)
    XCTAssertEqual(try OriginalCache.clear(root).remaining.entryCount,0)
  }

}
