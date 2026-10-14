#!/usr/bin/env python3
"""Production AppModel cleanup gates and persistence, using temporary files only."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/OCloudSync/AppModel.swift').read_text()
def extract(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
methods = [extract(s) for s in ['  var cacheCleanupBlockedReason:', '  func refreshCacheStatistics()', '  func clearOriginalCache()', '  func clearImportQueue()']]
harness = r'''
import Foundation
@MainActor final class Model {
 var ledger = Ledger(), busy = false, fatal: String?, cache: URL?
 var cacheStatistics: CacheStatistics?, cacheStatisticsBusy = false, clearingCache = false, cacheStatus = ""
 var work: Task<Void,Never>?, queueBatchID: UUID?, importProgress: Int?, localRecoveryProgress: Int?
 var completed = 0, total = 0, nextScan = Date.distantPast, intervalMinutes = 60, status = ""
 var persistFails = false, saved = false
 func persist(_ value: Ledger) throws {
   if persistFails { throw SyncFailure("disk failure") }
   saved = true; ledger = value
 }
 func stopForStorage(_ error: Error) { fatal = error.localizedDescription }
 func clearRangePreview() {}
 __METHODS__
}
@main struct Regression {
 @MainActor static func main() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let file = folder.appendingPathComponent("original.jpg")
  try Data([1,2,3]).write(to: file)
  let model = Model(); model.cache = folder
  let asset = RemoteAsset(account: "a",remoteID: "a",fileID: "a",filename: "a.jpg",bytes: 3,width: 1,height: 1,mediaType: 1,version: "v",isMotion: false)
  model.ledger.records[asset.key] = SyncRecord(asset: asset,state: .pending)
  model.ledger.importBatches = [ImportBatch(source: .automatic, keys: [asset.key])]
  model.busy = true
  model.clearImportQueue(); model.clearOriginalCache()
  precondition(!model.saved && model.ledger.queueRecords().count == 1)
  precondition(FileManager.default.fileExists(atPath: file.path))
  model.busy = false; model.persistFails = true
  model.clearImportQueue()
  precondition(model.fatal != nil && model.ledger.queueRecords().count == 1)
  model.fatal = nil; model.persistFails = false
  model.ledger.records[asset.key]?.state = .importing
  model.clearOriginalCache()
  precondition(!model.busy && FileManager.default.fileExists(atPath: file.path))
  model.clearImportQueue()
  precondition(model.ledger.queueRecords().isEmpty && model.saved)
  precondition(model.ledger.records[asset.key]?.queueCancelledAt != nil)
  // Cancelled uncertain transactions retain their journal without locking cache cleanup.
  model.cacheStatisticsBusy = true; model.clearOriginalCache()
  precondition(!model.busy && FileManager.default.fileExists(atPath: file.path))
  model.cacheStatisticsBusy = false
  model.clearOriginalCache()
  precondition(model.busy && model.clearingCache)
  let job = model.work!
  job.cancel() // Stop requests must still drain filesystem cleanup before reopening the pipeline.
  await job.value
  precondition(!model.busy && !model.clearingCache && model.work == nil)
  precondition(model.cacheStatistics?.entryCount == 0 && !FileManager.default.fileExists(atPath: file.path))
  precondition(model.ledger.records[asset.key]?.state == .importing && model.ledger.records[asset.key]?.queueCancelledAt != nil)
  print("PASS: production cleanup busy/persistence/journal gates and cancellation drain; Photos records retained")
 }
}
'''.replace('__METHODS__', '\n'.join(methods))
with tempfile.TemporaryDirectory(prefix='ocloud-cleanup-') as folder:
    swift, binary = Path(folder) / 'Regression.swift', Path(folder) / 'regression'
    swift.write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', *map(str, sorted((root / 'Sources/SyncCore').glob('*.swift'))), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
