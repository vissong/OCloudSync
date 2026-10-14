import Foundation

public struct ImportBatch: Codable, Identifiable, Sendable {
  public enum Source: String, Codable, Sendable { case dateRange, automatic, legacy }
  public let id: UUID
  public let source: Source
  public let createdAt: Date
  public let recordKeys: [String]
  public let range: ImportDateRange?
  public init(source: Source, keys: [String], range: ImportDateRange? = nil, createdAt: Date = Date()) {
    id = UUID(); self.source = source; self.createdAt = createdAt
    var seen = Set<String>()
    recordKeys = keys.filter { seen.insert($0).inserted }
    self.range = range
  }
  public var title: String {
    switch source {
    case .dateRange:
      guard let range else { return "按时间导入" }
      var format = Date.FormatStyle(date: .numeric)
      format.timeZone = TimeZone(identifier: range.timeZoneIdentifier) ?? .current
      return "\(range.start.formatted(format)) – \(range.endExclusive.addingTimeInterval(-1).formatted(format))"
    case .automatic: return "自动新增 · \(createdAt.formatted(date: .numeric, time: .shortened))"
    case .legacy: return "升级前未完成任务"
    }
  }
}

public enum QueueFilter: String, CaseIterable {
  case all = "全部", pending = "待处理", failed = "失败／无法处理", completed = "已完成"
  public func includes(_ record: SyncRecord) -> Bool {
    switch self {
    case .all: return true
    case .pending: return [.pending,.downloading,.downloaded].contains(record.state)
      || (record.state == .importing && record.error == nil)
    case .failed: return [.failed,.unavailable,.unsupported].contains(record.state)
      || (record.state == .importing && record.error != nil)
    case .completed: return [.imported,.duplicate].contains(record.state)
    }
  }
}

public struct QueueSummary {
  public let total: Int
  public private(set) var imported = 0, duplicates = 0, failed = 0, waiting = 0, active = 0, blocked = 0
  public var successful: Int { imported + duplicates }
  public var remaining: Int { total - successful }
  public init(records: [SyncRecord], total: Int? = nil, activeKey: String? = nil) {
    self.total = total ?? records.count
    blocked = self.total - records.count
    for record in records {
      if record.id == activeKey && ![.imported,.duplicate,.unavailable,.unsupported].contains(record.state) {
        active += 1
        continue
      }
      switch record.state {
      case .imported: imported += 1
      case .duplicate: duplicates += 1
      case .failed: failed += 1
      case .importing where record.error != nil: failed += 1
      case .downloading, .importing: active += 1
      case .pending, .downloaded: waiting += 1
      default: blocked += 1
      }
    }
  }
}

extension Ledger {
  /// Preserve identity and any uncertain PhotoKit transaction; only explicit re-selection resumes it.
  public mutating func clearImportQueue(now: Date = Date()) {
    let keys = Set((importBatches ?? []).flatMap(\.recordKeys))
    for key in Array(records.keys) {
      guard var record = records[key], ![.baseline,.imported,.duplicate].contains(record.state),
        keys.contains(key) || [.pending,.downloading,.downloaded,.importing,.failed,.unavailable].contains(record.state)
      else { continue }
      record.queueCancelledAt = now
      record.nextAttempt = nil
      record.updatedAt = now
      if record.state != .importing { record.error = nil }
      records[key] = record
    }
    importBatches = []
  }
  /// Old releases did not save range selections. Preserve only the unfinished work we can prove.
  public mutating func migrateImportQueue(now: Date = Date()) {
    guard importBatches == nil else { return }
    let keys = records.values.filter {
      $0.queueCancelledAt == nil && [.pending,.downloading,.downloaded,.importing,.failed,.unavailable].contains($0.state)
    }.sorted { $0.id < $1.id }.map(\.id)
    importBatches = keys.isEmpty ? [] : [ImportBatch(source: .legacy,keys: keys,createdAt: now)]
  }
  public func queueRecords(batchID: UUID? = nil) -> [SyncRecord] {
    let keys: [String]
    if let batchID { keys = importBatches?.first(where: { $0.id == batchID })?.recordKeys ?? [] }
    else { keys = Array(Set((importBatches ?? []).flatMap(\.recordKeys))) }
    return keys.compactMap { records[$0] }.sorted {
      let a = $0.asset.captureDate ?? .distantPast, b = $1.asset.captureDate ?? .distantPast
      return a == b ? $0.id < $1.id : a < b
    }
  }
  public func queueSummary(keys: [String], activeKey: String? = nil) -> QueueSummary {
    let unique = Set(keys)
    return QueueSummary(records: unique.compactMap { records[$0] },total: unique.count,activeKey: activeKey)
  }
}
