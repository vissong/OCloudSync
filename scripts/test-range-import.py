#!/usr/bin/env python3
"""Run actual AppModel range orchestration with offline cloud/Photos spies."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / "Sources/OCloudSync/AppModel.swift").read_text()
def extract(signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]
harness = r'''
import Foundation
@MainActor final class Importer {
  var allowed = true
  func checkPermission() throws { if !allowed { throw SyncFailure("permission") } }
}
@MainActor final class Web {
  var result: ScanResult!
  var needsRescan = false
  var calls = 0
  var cancelScan = false
  var onScanMessage: ((String) -> Void)?
  var retryMessage: String?
  var scanError: Error?
  func maintainSession() {}
  func scan(ledger: Ledger = Ledger(), forceFull: Bool = false, pendingAccounts: Set<String> = [], progress: (Int,Int)->Void) async throws -> ScanResult {
    calls += 1
    if let retryMessage { onScanMessage?(retryMessage) }
    await Task.yield()
    if let scanError { throw scanError }
    if cancelScan { throw CancellationError() }
    progress(result.assets.count,result.assets.count)
    return result
  }
}
@MainActor final class Model {
  var ledger = Ledger(), busy = false, fatal: String?, rangePreview: DateRangePreview?
  var rangeStatus = "", rangeSelected = Set<String>(), rangePageOpen = true, rangeImporting = false
  var showQueue = false
  var queueBatchID: UUID?
  var work: Task<Void,Never>?, importer: Importer? = Importer(), cache: URL? = URL(fileURLWithPath:"/unused")
  var activeAccount: String?, completed = 0, total = 0, status = "", intervalMinutes = 15
  var importProgress: ImportProgress?
  var localRecoveryProgress: ImportProgress?, importProgressIsRange = false
  var enabled = false, session = SessionLease(), nextScan = Date.distantPast, runs = 0
  let web = Web()
  init() {
__CALLBACK__
  }
  var processed = [String](), failSession = false, failFile = false, persisted = 0
  func run() { runs += 1 }
  func fireTimer() { tick() }
  func persist(_ value: Ledger) throws { ledger=value; persisted += 1 }
  func stopForStorage(_ error: Error) { fatal="storage" }
  func process(_ record: SyncRecord, importer: Importer, cache: URL, sourceAvailable: Bool?) async throws {
    precondition(sourceAvailable == true)
    precondition(ledger.importBatches?.last?.recordKeys.contains(record.id) == true)
    precondition(!rangeImporting || showQueue)
    processed.append(record.id)
    var r = record
    if failSession { r.state = .downloading; ledger.records[r.id]=r; throw SessionAccessFailure(.loginRequired) }
    if failFile { throw SyncFailure("download failed") }
    r.state = .imported; ledger.records[r.id]=r
  }
  func recordFailure(_ error: Error, for record: SyncRecord, onRecorded: (() -> Void)? = nil) throws {
    if error is SessionAccessFailure { throw error }
    var r = ledger.records[record.id] ?? record; r.fail("retryable"); ledger.records[r.id]=r
    onRecorded?()
  }
  // Queue selection is exercised here; actual pipeline stages have separate production-spy tests.
  func processQueue(_ records: [SyncRecord], importer: Importer, cache: URL,
    present: Set<String>, isRange: Bool = false) async throws {
    total = records.count; completed = 0
    for r in records {
      do { try await process(r, importer: importer, cache: cache, sourceAvailable: present.contains(r.id)) }
      catch { try recordFailure(error, for: r) }
      completed += 1
    }
  }
__METHODS__
}
@main struct Regression {
 @MainActor static func main() async throws {
   let now = Date()
   let capture = ISO8601DateFormatter().date(from:"2026-10-01T12:00:00Z")!
   func asset(_ id: String) -> RemoteAsset {
     RemoteAsset(account:"a",remoteID:id,fileID:id,filename:id+".jpg",bytes:100,width:10,height:10,
       mediaType:1,version:"v1",isMotion:false,dateTakenMilliseconds:Int64(capture.timeIntervalSince1970*1000))
   }
   let a=asset("selected"), b=asset("unselected"), pending=asset("other-pending")
   let scan=ScanResult(account:"a",assets:[a,b,pending],headKeys:[a.key,b.key,pending.key],
     summary:ScanSummary(complete:true,scanned:3,total:3,listRequests:1,seconds:0,checkedAt:now,reason:"test"))
   let model=Model(); model.web.result=scan
   try model.ledger.mergeScan([a,b],account:"a",complete:true)
   model.ledger.records[pending.key]=SyncRecord(asset:pending,state:.pending)
   let before=model.ledger
   model.previewRange(start:capture,end:capture,photos:true,videos:true)
   await model.work?.value
   precondition(model.persisted == 0 && model.processed.isEmpty && model.rangePreview != nil)
   precondition(model.rangeSelected == [a.key,b.key])
   model.rangeSelected=[a.key]; model.importRange(); await model.work?.value
   precondition(!model.enabled && model.processed == [a.key])
   precondition(model.ledger.records[b.key]?.state == .baseline)
   precondition(model.ledger.records[pending.key]?.state == .pending)
   precondition(model.ledger.accounts == before.accounts && !model.rangeImporting && !model.busy)
   precondition(model.rangePreview == nil)
   precondition(model.queueBatchID == model.ledger.importBatches?.last?.id)
   precondition(model.ledger.importBatches?.last?.recordKeys == [a.key])
   // A mid-download session failure must make the selected work recoverable.
   model.ledger=before; model.processed=[]; model.failSession=true
   model.previewRange(start:capture,end:capture,photos:true,videos:true); await model.work?.value
   model.rangeSelected=[a.key]; model.importRange(); await model.work?.value
   precondition(model.ledger.records[a.key]?.state == .pending && model.processed == [a.key])
   precondition(model.status == SessionState.loginRequired.label, "queue hid session pause reason")
   // Permission/cancelled scan never queue historical files.
   model.ledger=before; model.processed=[]; model.failSession=false
   model.previewRange(start:capture,end:capture,photos:true,videos:true); await model.work?.value
   model.importer?.allowed=false; model.importRange(); await model.work?.value
   precondition(model.ledger.records[a.key]?.state == .baseline && model.processed.isEmpty)
   model.importer?.allowed=true; model.web.cancelScan=true
   model.previewRange(start:capture,end:capture,photos:true,videos:true); await model.work?.value
   precondition(model.rangePreview == nil && model.ledger.records[a.key]?.state == .baseline)
   // Auto timers must not drain work while the user reviews a selection.
   model.enabled=true; model.session=SessionLease()
   let token=model.session.begin(at:now)!
   model.session.finish(SessionReply(kind:.active,code:200),id:token,at:now)
   model.fireTimer(); precondition(model.runs == 0)
   model.leaveRangePage(); model.fireTimer(); precondition(model.runs == 1)
   precondition(model.rangePreview == nil && !model.rangePageOpen)
   model.rangePageOpen=true; model.web.cancelScan=false
   model.previewRange(start:capture,end:capture,photos:true,videos:true)
   let pendingPreview=model.work
   model.leaveRangePage(); await pendingPreview?.value
   precondition(!model.rangePageOpen && model.rangePreview == nil && !model.busy)
   for error in [CancellationError(), SyncFailure("retries exhausted"), nil] as [Error?] {
     let previewOnly = Model(); previewOnly.web.result = scan
     previewOnly.status = "overview idle"
     previewOnly.web.retryMessage = "15 秒后重试（1/3）"
     previewOnly.web.scanError = error
     previewOnly.previewRange(start:capture,end:capture,photos:true,videos:true)
     await previewOnly.work?.value
     precondition(previewOnly.status == "overview idle", "preview left a stale retry message in overview")
     precondition(previewOnly.rangeStatus != previewOnly.web.retryMessage)
     precondition(!previewOnly.busy && previewOnly.persisted == 0)
   }
   print("PASS: preview read-only, selected-only manual import, unrelated queue preserved, session recovery, permission/cancellation")
 }
}
'''

harness = harness.replace("__CALLBACK__", extract("      web.onScanMessage = "))
harness = harness.replace("__METHODS__", "\n".join(extract(s) for s in ["  func leaveRangePage(", "  func clearRangePreview(", "  func previewRange(", "  func importRange(", "  func cancelRangeWork(", "  private func tick("]))
resume = harness[:harness.index("   let model=Model()")] + r'''
   let fresh=Model(); fresh.web.result=scan; fresh.rangePageOpen=false
   let preview=try DateRangePreview(scan:scan,range:ImportDateRange(startDay:capture,endDay:capture),includePhotos:true,includeVideos:true)
   _ = try fresh.ledger.queueRangeImport(preview,selectedKeys:[a.key],freshScan:scan,now:now)
   precondition(fresh.ledger.accounts.isEmpty && fresh.ledger.records[a.key]?.state == .pending)
   fresh.run(); await fresh.work?.value
   precondition(!fresh.enabled && fresh.processed == [a.key], "first scan did not resume selected manual import")
   precondition(fresh.ledger.records[a.key]?.state == .imported)
   precondition(fresh.ledger.records[b.key]?.state == .baseline)
   precondition(fresh.ledger.records[pending.key]?.state == .baseline)
   print("PASS: first automatic baseline resumes previously selected manual work only")
 }
}
'''
resume = resume.replace("  func run() { runs += 1 }", extract("  func run(forceFull:") + "\n" + extract("  private func recoverLocalWork("))
for scenario in [harness, resume]:
 with tempfile.TemporaryDirectory(prefix="ocloud-range-import-") as folder:
    swift = Path(folder) / "Regression.swift"
    binary = Path(folder) / "regression"
    swift.write_text(scenario)
    subprocess.run(["swiftc", "-parse-as-library", *map(str, sorted((root / "Sources/SyncCore").glob("*.swift"))), str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
