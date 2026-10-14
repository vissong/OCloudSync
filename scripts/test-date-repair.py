#!/usr/bin/env python3
"""Exercise production date repair with a PhotoKit spy, without accessing a library."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
importer = (root / "Sources/OCloudSync/PhotoImporter.swift").read_text()
def extract(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]

harness = r'''
import Foundation
struct SyncFailure: Error { init(_ text: String) {} }
enum RecordState { case imported, duplicate, importing, failed }
struct RemoteAsset {
  let filename = "synthetic.mp4", isVideo = true
  var captureDate: Date? = Date(timeIntervalSince1970: 1_700_000_000)
  static func hashFile(_ file: URL) throws -> String { "hash" }
}
struct SyncRecord {
  let id = "synthetic"
  var asset = RemoteAsset(), state = RecordState.imported
  var photoID: String? = "owned", sha256: String? = "hash"
  var livePhoto: LivePhotoManifest?
  var nextAttempt: Date?, error: String?
  mutating func fail(_ message: String, importWasNotCommitted: Bool = false) { error = message }
}
struct LivePhotoManifest: Codable, Equatable { let sourceHash: String }
struct ResolvedMediaDate: Codable {
  let date: Date
}
enum MediaDateResolver {
  static var resolvedDateOverride: Date?
  static func resolve(asset: RemoteAsset, file: URL) throws -> ResolvedMediaDate {
    guard let date = resolvedDateOverride ?? asset.captureDate else { throw SyncFailure("missing original creation date") }
    return ResolvedMediaDate(date: date)
  }
}
enum MediaType { case video, image }
enum Operation { case properties }
struct Fetch { let firstObject: PHAsset? }
final class PHAsset {
  static let owned = PHAsset()
  let localIdentifier = "owned"
  var creationDate: Date? = Date(timeIntervalSince1970: 1_800_000_000)
  var mediaType = MediaType.video
  var editable = true
  static func fetchAssets(withLocalIdentifiers ids: [String], options: Int) -> Fetch {
    Fetch(firstObject: ids == ["owned"] ? owned : nil)
  }
  func canPerform(_ op: Operation) -> Bool { editable }
}
final class PHAssetChangeRequest {
  let asset: PHAsset
  init(for asset: PHAsset) { self.asset = asset }
  var creationDate: Date? { get { asset.creationDate } set { asset.creationDate = newValue } }
}
final class PHPhotoLibrary {
  static let library = PHPhotoLibrary()
  static func shared() -> PHPhotoLibrary { library }
  var writes = 0, reject = false, loseDate = false, interruptAfterCommit = false
  func performChanges(_ changes: () -> Void) async throws {
    if reject { throw SyncFailure("rejected") }
    writes += 1; changes()
    if interruptAfterCommit { throw SyncFailure("simulated termination after commit") }
    if loseDate { PHAsset.owned.creationDate = nil }
  }
}
final class PhotoImporter {
  __RECEIPT__
  let journalDirectory: URL
  init(_ directory: URL) { journalDirectory = directory }
  func checkPermission() throws {}
  func lookupOptions() -> Int { 0 }
  __READ_RECEIPT__
  __VERIFY_DATE__
}
__DATE_FAILURE__
struct ConfirmedImportFailure: Error {}
struct StaticFallbackInfo: Codable { let sourceHash: String; let stillHash: String; let reason: String }
struct VideoCompatibilityInfo: Codable { let sourceHash: String; let importHash: String }
enum SessionState { case loginRequired }
struct SessionAccessFailure: Error { init(_ state: SessionState) {} }
struct WebSpy { var requiresLogin = false }
struct Ledger { var records = [String: SyncRecord]() }
final class ModelSpy {
  var ledger = Ledger(), web = WebSpy(), fatal: String?
  func save(_ record: SyncRecord) throws { ledger.records[record.id] = record }
  __RECORD_FAILURE__
}
__POLICY__
__REPAIR__
@main struct Regression {
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let journals = root.appendingPathComponent("imports")
    try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let spy = PhotoImporter(journals), record = SyncRecord()
    let journal = journals.appendingPathComponent("synthetic.json")
    // Legacy receipts decode with no mediaDate, preserving compatibility.
    let legacy = Data(#"{"photoID":"owned","sourceHash":"hash"}"#.utf8)
    try legacy.write(to: journal)
    var committing = record; committing.state = .importing; committing.photoID = nil
    let model = ModelSpy(); model.ledger.records[record.id] = committing
    try model.recordFailure(DateVerificationPending(photoID: "owned"), for: committing)
    let committed = model.ledger.records[record.id]!
    precondition(committed.state == .imported && committed.photoID == "owned" && committed.error != nil)
    var pendingDate = PhotoImporter.Receipt(photoID: "owned", sourceHash: "hash")
    pendingDate.mediaDate = ResolvedMediaDate(date: record.asset.captureDate!)
    try JSONEncoder().encode(pendingDate).write(to: journal)
    let needsDate = try await spy.previewDates([committed], cache: root) { _, _ in }
    precondition(needsDate.items.count == 1, "committed date failure cannot be repaired")
    try legacy.write(to: journal)
    let plan = try await spy.previewDates([record], cache: root) { _, _ in }
    precondition(plan.items.count == 1 && plan.items[0].isVideo)
    let audit = try spy.saveDateAudit(plan)
    let backup = try JSONDecoder().decode(PhotoDatePreview.self, from: Data(contentsOf: audit))
    precondition(backup.items[0].before == PHAsset.owned.creationDate)
    let permissions = try FileManager.default.attributesOfItem(atPath: audit.path)[.posixPermissions] as! NSNumber
    precondition(permissions.intValue == 0o600)
    try await spy.repairDate(plan.items[0], record: record)
    precondition(PHAsset.owned.creationDate == record.asset.captureDate && PHPhotoLibrary.library.writes == 1)
    let saved = try spy.receipt(for: record.id)
    precondition(saved?.mediaDate?.date == record.asset.captureDate)
    try await spy.repairDate(plan.items[0], record: record)
    precondition(PHPhotoLibrary.library.writes == 1, "retry changed an already correct date")
    let finishWarning = try await spy.previewDates([committed], cache: root) { _, _ in }
    precondition(finishWarning.items.count == 1, "resolved date warning cannot be finalized")
    let correct = try await spy.previewDates([record], cache: root) { _, _ in }
    precondition(correct.items.isEmpty && correct.correct == 1)
    var localOnly = record; localOnly.asset.captureDate = nil
    MediaDateResolver.resolvedDateOverride = record.asset.captureDate!.addingTimeInterval(3600)
    let stable = try await spy.previewDates([localOnly], cache: root) { _, _ in }
    precondition(stable.items.isEmpty && stable.correct == 1, "persisted date reinterpreted after time zone change")
    MediaDateResolver.resolvedDateOverride = nil
    PHAsset.owned.creationDate = record.asset.captureDate!.addingTimeInterval(3600)
    let edited = try await spy.previewDates([record], cache: root) { _, _ in }
    precondition(edited.skipped == 1 && edited.items.isEmpty, "manual edit overwritten")
    do { try await spy.repairDate(plan.items[0], record: record); fatalError("stale preview accepted") } catch {}
    precondition(PHPhotoLibrary.library.writes == 1)
    try legacy.write(to: journal)
    let retry = try await spy.previewDates([record], cache: root) { _, _ in }
    PHPhotoLibrary.library.reject = true
    do { try await spy.repairDate(retry.items[0], record: record); fatalError("failure ignored") } catch {}
    let rejectedReceipt = try spy.receipt(for: record.id)!
    precondition(rejectedReceipt.dateVerified != true && rejectedReceipt.pendingDate != nil, "failed change lost repair intent")
    PHPhotoLibrary.library.reject = false
    PHPhotoLibrary.library.loseDate = true
    do { try await spy.repairDate(retry.items[0], record: record); fatalError("readback ignored") } catch {}
    let unverifiedReceipt = try spy.receipt(for: record.id)!
    precondition(unverifiedReceipt.dateVerified != true && unverifiedReceipt.pendingDate != nil)
    var duplicate = record; duplicate.state = .duplicate
    var wrong = record; wrong.photoID = "unowned"
    var noDate = record; noDate.asset.captureDate = nil
    let skipped = try await spy.previewDates([duplicate, wrong, noDate], cache: root) { _, _ in }
    precondition(skipped.items.isEmpty && skipped.skipped == 3)
    PHPhotoLibrary.library.loseDate = false
    try legacy.write(to: journal)
    PHAsset.owned.creationDate = Date(timeIntervalSince1970: 1_800_000_000)
    let interrupted = try await spy.previewDates([record], cache: root) { _, _ in }
    PHPhotoLibrary.library.interruptAfterCommit = true
    do { try await spy.repairDate(interrupted.items[0], record: record); fatalError("interruption ignored") } catch {}
    PHPhotoLibrary.library.interruptAfterCommit = false
    let resume = try await spy.previewDates([record], cache: root) { _, _ in }
    precondition(resume.items.count == 1, "committed repair lost its pending confirmation")
    let writes = PHPhotoLibrary.library.writes
    try await spy.repairDate(resume.items[0], record: record)
    precondition(PHPhotoLibrary.library.writes == writes, "resumed confirmation rewrote the date")
    PHAsset.owned.creationDate = record.asset.captureDate!.addingTimeInterval(3600)
    let protected = try await spy.previewDates([record], cache: root) { _, _ in }
    precondition(protected.skipped == 1, "edit after resumed repair unprotected")
    try legacy.write(to: journal)
    PHAsset.owned.creationDate = Date(timeIntervalSince1970: 1_800_000_000)
    let pendingPlan = try await spy.previewDates([record], cache: root) { _, _ in }
    PHPhotoLibrary.library.interruptAfterCommit = true
    do { try await spy.repairDate(pendingPlan.items[0], record: record); fatalError("interruption ignored") } catch {}
    PHPhotoLibrary.library.interruptAfterCommit = false
    PHAsset.owned.creationDate = record.asset.captureDate!.addingTimeInterval(7200)
    let editedPending = try await spy.previewDates([record], cache: root) { _, _ in }
    precondition(editedPending.skipped == 1 && editedPending.items.isEmpty, "manual edit after interrupted repair overwritten")
    print("PASS: date repair ownership, legacy receipts, audit, in-place writes, readback, retry and edit guards")
  }
}
'''
harness = harness.replace("__DATE_FAILURE__", extract(importer, "struct DateVerificationPending:"))
model = (root / "Sources/OCloudSync/AppModel.swift").read_text()
harness = harness.replace("__RECORD_FAILURE__", extract(model, "  private func recordFailure(").replace("private ", ""))
harness = harness.replace("__RECEIPT__", extract(importer, "  struct Receipt:"))
harness = harness.replace("__READ_RECEIPT__", extract(importer, "  func receipt("))
harness = harness.replace("__VERIFY_DATE__", extract(importer, "  func verifyCreationDate("))
harness = harness.replace("__POLICY__", (root / "Sources/SyncCore/DateRepairPolicy.swift").read_text().replace("public ", ""))
repair = (root / "Sources/OCloudSync/PhotoDateRepair.swift").read_text()
harness = harness.replace("__REPAIR__", repair.replace("import Photos", "").replace("import SyncCore", ""))
with tempfile.TemporaryDirectory(prefix="ocloud-date-repair-") as folder:
    source = Path(folder) / "Regression.swift"
    binary = Path(folder) / "regression"
    source.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
