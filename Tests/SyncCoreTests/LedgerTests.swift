import XCTest

@testable import SyncCore

final class LedgerTests: XCTestCase {
  func testAllHashCandidatesAreAvailableForLivePhotoLookup() {
    var l = Ledger()
    var a = SyncRecord(asset: asset("a"), state: .imported)
    a.sha256 = "same"
    a.photoID = "deleted"
    var b = SyncRecord(asset: asset("b"), state: .imported)
    b.sha256 = "same"
    b.photoID = "exists"
    l.records[a.id] = a
    l.records[b.id] = b
    XCTAssertEqual(
      Set(l.duplicates(hash: "same", excluding: "other", account: "u1").compactMap(\.photoID)),
      ["deleted", "exists"])
  }
  func asset(_ id: String = "a", size: Int64 = 12, version: String = "v1") -> RemoteAsset {
    RemoteAsset(
      account: "u1", remoteID: id, fileID: "file-" + id, filename: "A.heic", bytes: size, width: 3,
      height: 4, mediaType: 1, version: version, isMotion: false)
  }
  func testBaselineOnlyCommitsCompleteScan() throws {
    var l = Ledger()
    try l.mergeScan([asset()], account: "u1", complete: false)
    XCTAssertTrue(l.records.isEmpty)
    XCTAssertFalse(l.accounts.contains("u1"))
    try l.mergeScan([asset()], account: "u1", complete: true)
    XCTAssertEqual(l.records.values.first?.state, .baseline)
    try l.mergeScan([asset(), asset("b")], account: "u1", complete: true)
    XCTAssertEqual(l.due(at: Date()).map(\.asset.remoteID), ["b"])
  }
  func testChangedVersionCreatesPendingAndKeepsOldRecord() throws {
    var l = Ledger()
    try l.mergeScan([asset()], account: "u1", complete: true)
    try l.mergeScan([asset(version: "v2")], account: "u1", complete: true)
    XCTAssertEqual(l.records.count, 2)
    XCTAssertEqual(l.due(at: Date()).count, 1)
  }
  func testAccountIsolationAndRejectMixedScan() throws {
    var l = Ledger()
    XCTAssertThrowsError(try l.mergeScan([asset()], account: "u2", complete: true))
    XCTAssertTrue(l.accounts.isEmpty)
  }
  func testNoDedupByFilenameOrSize() throws {
    var l = Ledger()
    l.accounts.insert("u1")
    try l.mergeScan([asset(), asset("b")], account: "u1", complete: true)
    XCTAssertEqual(l.due(at: Date()).count, 2)
  }
  func testRetriesExponentialAndBounded() throws {
    var r = SyncRecord(asset: asset(), state: .pending)
    let now = Date(timeIntervalSince1970: 1000)
    r.fail("network", at: now)
    XCTAssertEqual(r.attempts, 1)
    XCTAssertEqual(r.nextAttempt!.timeIntervalSince(now), 30)
    for _ in 1..<6 { r.fail("network", at: now) }
    XCTAssertNil(r.nextAttempt)
    XCTAssertEqual(r.state, .failed)
  }
  func testImportRecoveryNeverBlindlyResets() throws {
    var l = Ledger()
    var r = SyncRecord(asset: asset(), state: .importing)
    r.photoID = "p1"
    l.records[r.id] = r
    l.recoverInterrupted()
    XCTAssertEqual(l.records[r.id]?.state, .importing)
    XCTAssertEqual(l.records[r.id]?.photoID, "p1")
  }
  func testAtomicStoreAndExclusiveLock() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = try LedgerStore(directory: dir)
    var l = Ledger()
    l.accounts.insert("u1")
    try s.save(l)
    XCTAssertEqual(try s.load().accounts, ["u1"])
    XCTAssertThrowsError(try LedgerStore(directory: dir))
  }
  func testFilenameTraversalDoesNotAffectCacheKey() throws {
    var a = asset()
    a.filename = "../../x.heic"
    XCTAssertFalse(a.key.contains("/"))
    XCTAssertEqual(a.key.count, 64)
  }
  func testCancelledDownloadCanResumeWithoutRestart() throws {
    var l = Ledger()
    let r = SyncRecord(asset: asset(), state: .downloading)
    l.records[r.id] = r
    l.recoverInterrupted()
    XCTAssertEqual(l.due(at: Date()).first?.id, r.id)
  }
  func testMissingSourceTerminalUntilItReappears() throws {
    var l = Ledger()
    l.accounts.insert("u1")
    var r = SyncRecord(asset: asset(), state: .unavailable)
    l.records[r.id] = r
    XCTAssertTrue(l.due(at: Date()).isEmpty)
    try l.mergeScan([asset()], account: "u1", complete: true)
    XCTAssertEqual(l.records[r.id]?.state, .pending)
    r.state = .importing
    l.records[r.id] = r
    try l.mergeScan([], account: "u1", complete: true)
    XCTAssertEqual(l.due(at: Date()).first?.state, .importing)
  }
  func testStaleDownloadCannotClaimOrFinishNewOperation() throws {
    var gate = OperationGate()
    let a = try gate.begin()
    gate.cancel(a)
    XCTAssertFalse(gate.accepts(a))
    XCTAssertThrowsError(try gate.begin())
    XCTAssertTrue(gate.finish(a))
    let b = try gate.begin()
    XCTAssertFalse(gate.accepts(a))
    XCTAssertFalse(gate.finish(a))
    XCTAssertTrue(gate.accepts(b))
  }
}
