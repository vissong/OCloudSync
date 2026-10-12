import XCTest

@testable import SyncCore

@MainActor
final class ScannerTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  private func assets(_ count: Int, account: String = "u1") -> [RemoteAsset] {
    (0..<count).map {
      RemoteAsset(
        account: account, remoteID: "id-\($0)", fileID: "file-\($0)",
        filename: "\($0).heic", bytes: 12, width: 3, height: 4, mediaType: 1,
        version: "v1", isMotion: false)
    }
  }
  private final class Source {
    var items: [RemoteAsset]
    var calls = 0
    var page = 1
    var loaded = 0
    var failAt: Int?
    init(_ items: [RemoteAsset]) { self.items = items }
    func load(_ request: ScanRequest) throws -> ScanPage {
      calls += 1
      if calls == failAt { throw SyncFailure("offline") }
      switch request {
      case .begin:
        page = 1
        loaded = 100
      case .page(let n):
        page = n
        loaded = 100
      case .next: loaded += 100
      }
      let start = (page - 1) * 1000
      let end = min(start + min(1000, loaded), items.count)
      return ScanPage(
        serial: calls, page: page, pageSize: 1000, total: items.count,
        final: end == min(start + 1000, items.count), finalPage: end == items.count,
        items: Array(items[start..<end]))
    }
  }
  private func scan(
    _ source: Source, _ ledger: Ledger = Ledger(), force: Bool = false,
    at: Date? = nil, pending: Set<String>? = nil
  ) async throws -> ScanResult {
    try await AlbumScanner.scan(
      ledger: ledger, forceFull: force,
      pendingAccounts: pending ?? Set(ledger.due(at: at ?? now).map { $0.asset.account }),
      now: at ?? now, load: { try source.load($0) }, progress: { _, _ in })
  }
  func testUnchanged6395ItemsNeedsOneBatchAfterRestart() async throws {
    let original = assets(6395)
    var ledger = Ledger()
    let full = try await scan(Source(original))
    XCTAssertTrue(full.complete)
    XCTAssertEqual(full.summary.listRequests, 64)
    try ledger.applyScan(full)
    ledger = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
    let quick = try await scan(Source(original), ledger, at: now.addingTimeInterval(900))
    XCTAssertFalse(quick.complete)
    XCTAssertEqual(quick.assets.count, 100)
    XCTAssertEqual(quick.summary.listRequests, 1)
    try ledger.applyScan(quick)
    XCTAssertEqual(ledger.records.count, 6395)
    XCTAssertTrue(ledger.records.values.allSatisfy { $0.state == .baseline })
    XCTAssertEqual(ledger.scanCheckpoints?["u1"]?.fullScanAt, now)
  }
  func testOldPhotoAddedBeyondHeadTriggersFullScan() async throws {
    let original = assets(250)
    var ledger = Ledger()
    try ledger.applyScan(try await scan(Source(original)))
    let result = try await scan(Source(assets(251)), ledger)
    XCTAssertTrue(result.complete)
    try ledger.applyScan(result)
    XCTAssertEqual(ledger.due(at: now).map(\.asset.remoteID), ["id-250"])
  }
  func testEqualCountReplacementOutsideHeadIsFoundByDailyFullScan() async throws {
    var original = assets(250)
    var ledger = Ledger()
    try ledger.applyScan(try await scan(Source(original)))
    original[249].version = "replacement"
    let quick = try await scan(Source(original), ledger, at: now.addingTimeInterval(900))
    XCTAssertFalse(quick.complete)
    try ledger.applyScan(quick)
    let daily = try await scan(Source(original), ledger, at: now.addingTimeInterval(86400))
    XCTAssertTrue(daily.complete)
    try ledger.applyScan(daily)
    XCTAssertEqual(ledger.due(at: now).first?.asset.version, "replacement")
  }
  func testHeadChangeManualCheckAndRetriesForceFullScan() async throws {
    var original = assets(250)
    var ledger = Ledger()
    try ledger.applyScan(try await scan(Source(original)))
    let manual = try await scan(Source(original), ledger, force: true)
    let retry = try await scan(Source(original), ledger, pending: ["u1"])
    XCTAssertTrue(manual.complete)
    XCTAssertTrue(retry.complete)
    original[0].version = "v2"
    let changed = try await scan(Source(original), ledger)
    XCTAssertTrue(changed.complete)
  }
  func testOtherAccountAlwaysBuildsItsOwnCompleteBaseline() async throws {
    var ledger = Ledger()
    try ledger.applyScan(try await scan(Source(assets(250))))
    let other = try await scan(Source(assets(250, account: "u2")), ledger)
    XCTAssertTrue(other.complete)
    try ledger.applyScan(other)
    XCTAssertEqual(ledger.accounts, ["u1", "u2"])
    XCTAssertEqual(ledger.records.count, 500)
    XCTAssertTrue(ledger.due(at: now).isEmpty)
  }
  func testFailedFullScanDoesNotAdvanceCheckpoint() async throws {
    var ledger = Ledger()
    try ledger.applyScan(try await scan(Source(assets(250))))
    let source = Source(assets(251))
    source.failAt = 2
    do {
      _ = try await scan(source, ledger)
      XCTFail("Expected request failure")
    } catch {}
    XCTAssertEqual(ledger.scanCheckpoints?["u1"]?.total, 250)
    XCTAssertEqual(ledger.records.count, 250)
  }
  func testLegacyLedgerRequiresOneFullScanAndRetainsBaseline() async throws {
    var legacy = Ledger()
    try legacy.mergeScan(assets(250), account: "u1", complete: true)
    var object =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
    object.removeValue(forKey: "scanCheckpoints")
    object.removeValue(forKey: "lastCheck")
    var loaded = try JSONDecoder().decode(
      Ledger.self, from: JSONSerialization.data(withJSONObject: object))
    let result = try await scan(Source(assets(250)), loaded)
    XCTAssertTrue(result.complete)
    try loaded.applyScan(result)
    XCTAssertTrue(loaded.due(at: now).isEmpty)
  }
  func testPartialResultCannotEstablishBaseline() async throws {
    var ledger = Ledger()
    let full = try await scan(Source(assets(250)))
    try ledger.applyScan(full)
    let quick = try await scan(Source(assets(250)), ledger)
    var empty = Ledger()
    XCTAssertThrowsError(try empty.applyScan(quick))
    XCTAssertTrue(empty.records.isEmpty)
  }

  func testBrokenLocalCacheStillChecksCloudWithoutWaitingForDailyScan() async throws {
    var ledger = Ledger()
    try ledger.applyScan(try await scan(Source(assets(250))))
    try ledger.applyScan(try await scan(Source(assets(251)), ledger))
    let record = try XCTUnwrap(ledger.due(at: now).first)
    // Local recovery could not validate the cache or find a completed Photos transaction.
    ledger.records[record.id]?.deferMissingOriginal(sourceIsAbsent: false)
    XCTAssertEqual(ledger.records[record.id]?.state, .pending)
    // A failed remote scan must not lose this intent, even after a restart.
    let failing = Source(assets(251))
    failing.failAt = 1
    do {
      _ = try await scan(failing, ledger)
      XCTFail("Expected failure")
    } catch {}
    ledger = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
    let result = try await scan(Source(assets(251)), ledger)
    XCTAssertTrue(result.complete)
    try ledger.applyScan(result)
    XCTAssertEqual(ledger.due(at: now).map(\.id), [record.id])
    ledger.records[record.id]?.deferMissingOriginal(sourceIsAbsent: true)
    XCTAssertEqual(ledger.records[record.id]?.state, .unavailable)
    XCTAssertTrue(ledger.due(at: now).isEmpty)
  }
}
