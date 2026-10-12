import CryptoKit
import Darwin
import Foundation

public struct SyncFailure: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public struct RemoteAsset: Codable, Equatable, Sendable {
  public var account: String
  public var remoteID: String
  public var fileID: String
  public var filename: String
  public var bytes: Int64
  public var width: Int
  public var height: Int
  public var mediaType: Int
  public var version: String
  public var isMotion: Bool
  // OPPO datetaken is Unix milliseconds; optional for existing schema-1 ledgers.
  public var dateTakenMilliseconds: Int64?
  public init(
    account: String, remoteID: String, fileID: String, filename: String, bytes: Int64, width: Int,
    height: Int, mediaType: Int, version: String, isMotion: Bool,
    dateTakenMilliseconds: Int64? = nil
  ) {
    self.account = account
    self.remoteID = remoteID
    self.fileID = fileID
    self.filename = filename
    self.bytes = bytes
    self.width = width
    self.height = height
    self.mediaType = mediaType
    self.version = version
    self.isMotion = isMotion
    self.dateTakenMilliseconds = dateTakenMilliseconds
  }
  public var captureDate: Date? {
    guard let milliseconds = dateTakenMilliseconds, milliseconds > 0,
      milliseconds < 253_402_300_800_000 else { return nil }
    return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }
  public var key: String {
    Self.digest(Data([account, remoteID, version].joined(separator: "\u{0}").utf8))
  }
  public var supported: Bool {
    if isVideo { return !isMotion && ["mp4", "mov", "m4v"].contains((filename as NSString).pathExtension.lowercased()) }
    return mediaType == 1 && (!isMotion || isMotionJPEG)
      && ["jpg", "jpeg", "heic", "heif", "png"].contains(
        (filename as NSString).pathExtension.lowercased())
  }
  public var isMotionJPEG: Bool {
    mediaType == 1 && isMotion && ["jpg", "jpeg"].contains((filename as NSString).pathExtension.lowercased())
  }
  public var isVideo: Bool { mediaType == 3 }
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public static func hashFile(_ url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hash = SHA256()
    while let data = try h.read(upToCount: 1024 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

public enum RecordState: String, Codable, Sendable {
  case baseline, pending, downloading, downloaded, importing, imported, duplicate, unsupported,
    failed, unavailable
  public var label: String {
    switch self {
    case .baseline: return "历史基线"
    case .pending: return "等待同步"
    case .downloading: return "正在下载"
    case .downloaded: return "原图已校验"
    case .importing: return "正在导入"
    case .imported: return "已导入图库"
    case .duplicate: return "重复已跳过"
    case .unsupported: return "暂不支持"
    case .failed: return "等待重试"
    case .unavailable: return "源文件已移除或更新"
    }
  }
}
public struct SyncRecord: Codable, Identifiable, Sendable {
  public var id: String { asset.key }
  public var asset: RemoteAsset
  public var state: RecordState
  public var attempts = 0
  public var nextAttempt: Date?
  public var error: String?
  public var sha256: String?
  public var photoID: String?
  public var livePhoto: LivePhotoManifest?
  public var updatedAt = Date()
  public init(asset: RemoteAsset, state: RecordState) {
    self.asset = asset
    self.state = state
  }
  public mutating func deferMissingOriginal(sourceIsAbsent: Bool) {
    // Local cache failure cannot prove remote deletion. Keep that work durable and retryable.
    state = sourceIsAbsent ? .unavailable : .pending
    error = sourceIsAbsent ? "云端已无此版本，且没有可用的本地原图" : "本地原图不可用，等待重新核对云端文件"
    nextAttempt = nil
  }
  public mutating func fail(
    _ message: String, at date: Date = Date(), importWasNotCommitted: Bool = false
  ) {
    attempts += 1
    error = message
    updatedAt = date
    // Preserve uncertain PhotoKit transactions for reconciliation before retrying.
    if state != .importing || importWasNotCommitted { state = .failed }
    nextAttempt =
      attempts < 6 ? date.addingTimeInterval(min(30 * pow(2, Double(attempts - 1)), 1800)) : nil
  }
}
public struct Ledger: Codable {
  public var schemaVersion = 1
  public var accounts = Set<String>()
  public var records = [String: SyncRecord]()
  public var lastScan: Date?
  // Optional for compatibility with existing schema-1 ledgers.
  public var scanCheckpoints: [String: ScanCheckpoint]?
  public var lastCheck: ScanSummary?
  public var videoBaselineAccounts: Set<String>?
  public init() {}
  public mutating func applyScan(_ result: ScanResult) throws {
    if result.complete {
      guard Set(result.assets.map(\.key)).count == result.summary.total,
        !result.headKeys.isEmpty,
        Set(result.headKeys).isSubset(of: Set(result.assets.map(\.key)))
      else { throw SyncFailure("列表不完整，未提交检查点") }
      try mergeScan(result.assets, account: result.account, complete: true)
      if scanCheckpoints == nil { scanCheckpoints = [:] }
      scanCheckpoints?[result.account] = ScanCheckpoint(
        total: result.summary.total,
        headKeys: result.headKeys, fullScanAt: result.summary.checkedAt)
    } else {
      guard accounts.contains(result.account), videoBaselineAccounts?.contains(result.account) == true,
        let checkpoint = scanCheckpoints?[result.account],
        checkpoint.total == result.summary.total, checkpoint.headKeys == result.headKeys,
        result.assets.allSatisfy({ $0.account == result.account && records[$0.key] != nil })
      else { throw SyncFailure("轻量检查不能建立或替换历史基线，请完整核对") }
      // A partial inventory says nothing about unseen assets. Do not merge or mark them absent.
    }
    lastScan = result.summary.checkedAt
    lastCheck = result.summary
  }
  public mutating func mergeScan(_ assets: [RemoteAsset], account: String, complete: Bool) throws {
    guard complete else { return }
    guard !account.isEmpty,
      assets.allSatisfy({
        $0.account == account && !$0.remoteID.isEmpty && !$0.fileID.isEmpty && $0.bytes > 0
      })
    else { throw SyncFailure("云相册身份或文件信息不完整，未提交扫描") }
    let baseline = !accounts.contains(account)
    let videoBaseline = videoBaselineAccounts?.contains(account) != true
    if videoBaseline {
      for key in Array(records.keys) where records[key]?.asset.account == account
        && records[key]?.asset.isVideo == true
        && [.unsupported, .unavailable].contains(records[key]!.state)
      {
        records[key]?.state = .baseline
        records[key]?.error = nil
      }
    }
    for a in assets where records[a.key] == nil {
      records[a.key] = SyncRecord(
        asset: a, state: baseline || (videoBaseline && a.isVideo) ? .baseline : (a.supported ? .pending : .unsupported))
    }
    for a in assets where records[a.key]?.state == .unavailable {
      records[a.key]?.state = a.supported ? .pending : .unsupported
      records[a.key]?.error = nil
    }
    accounts.insert(account)
    if videoBaselineAccounts == nil { videoBaselineAccounts = [] }
    videoBaselineAccounts?.insert(account)
    lastScan = Date()
  }
  public func due(at: Date, account: String? = nil) -> [SyncRecord] {
    records.values.filter { r in
      if let account, account != r.asset.account { return false }
      switch r.state {
      case .pending, .downloaded: return true
      case .importing: return r.attempts == 0 || (r.nextAttempt.map { $0 <= at } ?? false)
      case .failed: return r.nextAttempt.map { $0 <= at } ?? false
      default: return false
      }
    }.sorted { $0.id < $1.id }
  }
  public mutating func recoverInterrupted() {
    for key in Array(records.keys) where records[key]?.state == .downloading {
      records[key]?.state = .pending
    }
    for key in Array(records.keys)
    where records[key]?.state == .unsupported && records[key]?.asset.supported == true
      && (!records[key]!.asset.isVideo || videoBaselineAccounts?.contains(records[key]!.asset.account) == true) {
      records[key]?.state = .pending
      records[key]?.error = nil
    }
  }
  public mutating func retryFailures() {
    for key in Array(records.keys)
    where records[key]?.state == .failed || records[key]?.state == .importing {
      records[key]?.attempts = 0
      records[key]?.nextAttempt = Date()
      records[key]?.error = nil
      if records[key]?.state == .failed { records[key]?.state = .pending }
    }
  }
  public func duplicates(hash: String, excluding: String, account: String) -> [SyncRecord] {
    records.values.filter {
      $0.id != excluding && $0.asset.account == account && $0.sha256 == hash
        && [.imported, .duplicate].contains($0.state) && $0.photoID != nil
    }
  }
}

/// A cancelled operation keeps its slot until cancellation has completed.
public struct OperationGate {
  public private(set) var active: UUID?
  private var cancelling = false
  public init() {}
  public mutating func begin() throws -> UUID {
    guard active == nil else { throw SyncFailure("上一项操作尚未结束") }
    let id = UUID()
    active = id
    cancelling = false
    return id
  }
  public func accepts(_ id: UUID) -> Bool { active == id && !cancelling }
  public mutating func cancel(_ id: UUID) { if active == id { cancelling = true } }
  public mutating func finish(_ id: UUID) -> Bool {
    guard active == id else { return false }
    active = nil
    cancelling = false
    return true
  }
}

/// One process owns the ledger. An unreadable ledger is never silently replaced.
public final class LedgerStore {
  public let directory: URL
  private let descriptor: Int32
  public init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    descriptor = open(directory.appendingPathComponent("sync.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw SyncFailure("无法创建同步锁") }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw SyncFailure("已有同步程序正在运行")
    }
  }
  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
  public func load() throws -> Ledger {
    let url = directory.appendingPathComponent("ledger.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return Ledger() }
    let l = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
    guard l.schemaVersion == 1 else { throw SyncFailure("不支持此版本的同步台账") }
    return l
  }
  public func save(_ ledger: Ledger) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let url = directory.appendingPathComponent("ledger.json")
    try encoder.encode(ledger).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let fd = open(url.path, O_RDONLY)
    if fd >= 0 {
      defer { close(fd) }
      guard fsync(fd) == 0 else { throw SyncFailure("同步台账写盘失败") }
    }
  }
}
