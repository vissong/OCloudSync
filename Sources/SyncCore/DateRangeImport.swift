import Foundation

public struct ImportDateRange: Codable, Equatable, Sendable {
  public let start: Date
  public let endExclusive: Date
  public let timeZoneIdentifier: String
  public init(startDay: Date, endDay: Date, timeZone: TimeZone = .current) throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let start = calendar.startOfDay(for: startDay)
    let end = calendar.startOfDay(for: endDay)
    guard start <= end, let next = calendar.date(byAdding: .day, value: 1, to: end) else {
      throw SyncFailure("结束日期不能早于开始日期")
    }
    self.start = start
    endExclusive = next
    timeZoneIdentifier = timeZone.identifier
  }
  public func contains(_ asset: RemoteAsset) -> Bool {
    guard let date = asset.captureDate else { return false }
    return date >= start && date < endExclusive
  }
}

public enum RangeImportEligibility: String {
  case ready = "可导入", completed = "已导入／已跳过", queued = "已在任务队列", unsupported = "暂不支持"
}

/// A read-only full inventory snapshot. It never establishes a baseline or starts downloads.
public struct DateRangePreview: Identifiable, Sendable {
  public let id = UUID()
  public let account: String
  public let createdAt: Date
  public let range: ImportDateRange
  public let includePhotos: Bool, includeVideos: Bool
  public let items: [RemoteAsset]
  public let missingDateCount: Int
  public let scannedCount: Int

  public init(scan: ScanResult, range: ImportDateRange, includePhotos: Bool, includeVideos: Bool) throws {
    try Self.validate(scan)
    guard includePhotos || includeVideos else { throw SyncFailure("请至少选择照片或视频") }
    account = scan.account
    createdAt = scan.summary.checkedAt
    self.range = range
    self.includePhotos = includePhotos
    self.includeVideos = includeVideos
    let typed = scan.assets.filter { ($0.mediaType == 1 && includePhotos) || ($0.isVideo && includeVideos) }
    missingDateCount = typed.filter { $0.captureDate == nil }.count
    scannedCount = scan.assets.count
    items = typed.filter { range.contains($0) }.sorted {
      if $0.captureDate != $1.captureDate { return $0.captureDate! < $1.captureDate! }
      return $0.key < $1.key
    }
  }
  static func validate(_ scan: ScanResult) throws {
    guard scan.complete, !scan.account.isEmpty, !scan.assets.isEmpty,
      scan.assets.count == scan.summary.total, Set(scan.assets.map(\.key)).count == scan.summary.total,
      scan.assets.allSatisfy({ $0.account == scan.account && !$0.remoteID.isEmpty && !$0.fileID.isEmpty && $0.bytes > 0 })
    else { throw SyncFailure("需要完整且属于同一账号的云相册清单，请重新预览") }
  }
  public func eligibility(_ asset: RemoteAsset, in ledger: Ledger) -> RangeImportEligibility {
    guard asset.supported else { return .unsupported }
    if let record = ledger.records[asset.key], record.queueCancelledAt != nil,
      ![.imported,.duplicate].contains(record.state) { return .ready }
    switch ledger.records[asset.key]?.state {
    case .imported?, .duplicate?: return .completed
    case .pending?, .downloading?, .downloaded?, .importing?: return .queued
    default: return .ready
    }
  }
  public func eligibleKeys(in ledger: Ledger) -> Set<String> {
    Set(items.filter { eligibility($0, in: ledger) == .ready }.map(\.key))
  }
}

extension Ledger {
  /// Validate the user's frozen selection against a fresh account inventory before any mutation.
  @discardableResult
  public mutating func queueRangeImport(
    _ preview: DateRangePreview, selectedKeys: Set<String>, freshScan: ScanResult, now: Date = Date()
  ) throws -> [String] {
    try DateRangePreview.validate(freshScan)
    guard freshScan.account == preview.account else { throw SyncFailure("OPPO 账号已变化，请重新预览") }
    guard now >= preview.createdAt, now.timeIntervalSince(preview.createdAt) <= 1800,
      freshScan.summary.checkedAt >= preview.createdAt else {
      throw SyncFailure("预览已超过 30 分钟或系统时间发生变化，请重新预览")
    }
    guard !selectedKeys.isEmpty, selectedKeys.isSubset(of: preview.eligibleKeys(in: self)) else {
      throw SyncFailure("请选择可导入项目；已处理或排队中的项目不会重复加入")
    }
    let fresh = try DateRangePreview(scan: freshScan, range: preview.range,
      includePhotos: preview.includePhotos, includeVideos: preview.includeVideos)
    guard selectedKeys.isSubset(of: fresh.eligibleKeys(in: self)) else {
      throw SyncFailure("选中的文件已移除、版本或拍摄时间发生变化，请重新预览")
    }
    let selected = fresh.items.filter { selectedKeys.contains($0.key) }
    for asset in selected {
      var record = records[asset.key] ?? SyncRecord(asset: asset, state: .pending)
      record.asset = asset
      if record.state != .importing { record.state = .pending }
      record.queueCancelledAt = nil
      record.attempts = 0
      record.nextAttempt = nil
      record.error = nil
      record.updatedAt = now
      records[asset.key] = record
    }
    let keys = selected.map(\.key)
    if importBatches == nil { importBatches = [] }
    importBatches?.append(ImportBatch(source: .dateRange,keys: keys,range: preview.range,createdAt: now))
    return keys
  }
}
