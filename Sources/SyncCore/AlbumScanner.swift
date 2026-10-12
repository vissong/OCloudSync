import Foundation

public struct ScanPage: Decodable {
  public let serial: Int, page: Int, pageSize: Int, total: Int
  public let final: Bool, finalPage: Bool
  public let items: [RemoteAsset]
}

public enum ScanRequest {
  case begin, next
  case page(Int)
}

public struct ScanCheckpoint: Codable {
  public let total: Int
  public let headKeys: [String]
  public let fullScanAt: Date
}

/// Safe to display/export: no account, asset IDs or filenames.
public struct ScanSummary: Codable {
  public let complete: Bool
  public let scanned: Int, total: Int, listRequests: Int
  public let seconds: Double
  public let checkedAt: Date
  public let reason: String
  public var label: String {
    "\(complete ? "完整核对" : "轻量检查")：读取 \(scanned) / \(total) 项，\(listRequests) 批列表，\(String(format: "%.1f", seconds)) 秒"
  }
}

public struct ScanResult {
  public let account: String
  public let assets: [RemoteAsset]
  public let headKeys: [String]
  public let summary: ScanSummary
  public var complete: Bool { summary.complete }
}

/// A head/count match is only a short-lived hint, never a complete source inventory.
@MainActor
public enum AlbumScanner {
  public static func scan(
    ledger: Ledger, forceFull: Bool = false, pendingAccounts: Set<String> = [],
    now: Date = Date(), load: (ScanRequest) async throws -> ScanPage,
    progress: (Int, Int) -> Void
  ) async throws -> ScanResult {
    let started = ProcessInfo.processInfo.systemUptime
    var requests = 1
    var page = try await load(.begin)
    let total = page.total
    guard total > 0 else { throw SyncFailure("云相册为空，暂无法确定账号身份；有照片后重新检查") }
    guard page.page == 1, page.pageSize > 0, let account = page.items.first?.account,
      !account.isEmpty, !page.items.isEmpty, page.items.count <= total,
      page.items.allSatisfy({ $0.account == account })
    else { throw SyncFailure("云相册首批数据不完整，本次不会更新检查点") }
    let headKeys = page.items.map(\.key).sorted()
    let checkpoint = ledger.scanCheckpoints?[account]
    let reason: String
    if forceFull {
      reason = "手动完整核对"
    } else if !ledger.accounts.contains(account) {
      reason = "建立账号历史基线"
    } else if ledger.videoBaselineAccounts?.contains(account) != true {
      reason = "建立视频历史基线"
    } else if checkpoint == nil {
      reason = "首次建立检查点"
    } else if pendingAccounts.contains(account) {
      reason = "核对待处理任务的源文件"
    } else if checkpoint!.total != total {
      reason = "云相册总数变化"
    } else if checkpoint!.headKeys != headKeys {
      reason = "首批照片或原图版本变化"
    } else if now.timeIntervalSince(checkpoint!.fullScanAt) >= 86400
      || now < checkpoint!.fullScanAt
    {
      reason = "每日完整核对"
    } else {
      reason = "总数与首批一致"
    }
    progress(page.items.count, total)
    if reason == "总数与首批一致" {
      try Task.checkCancellation()
      return ScanResult(
        account: account, assets: page.items, headKeys: headKeys,
        summary: ScanSummary(
          complete: false, scanned: page.items.count, total: total,
          listRequests: requests, seconds: ProcessInfo.processInfo.systemUptime - started,
          checkedAt: now, reason: reason))
    }
    var all = [String: RemoteAsset]()
    let pageSize = page.pageSize
    let pages = max(1, Int(ceil(Double(total) / Double(pageSize))))
    guard pages <= 1000 else { throw SyncFailure("相册规模超出本版扫描范围") }
    for index in 1...pages {
      if index > 1 {
        page = try await load(.page(index))
        requests += 1
      }
      var rounds = 0
      while true {
        try Task.checkCancellation()
        guard page.total == total, page.page == index, page.pageSize == pageSize else {
          throw SyncFailure("扫描过程中云相册发生变化，将在下一轮重新扫描")
        }
        for asset in page.items {
          guard asset.account == account else { throw SyncFailure("账号发生变化，本次扫描已停止") }
          all[asset.key] = asset
        }
        progress(all.count, total)
        if page.final { break }
        rounds += 1
        guard rounds < 50 else { throw SyncFailure("OPPO 分页游标没有正常结束") }
        page = try await load(.next)
        requests += 1
      }
    }
    guard all.count == total else {
      throw SyncFailure("列表未完整返回（\(all.count)/\(total)），不会提交不完整基线")
    }
    return ScanResult(
      account: account, assets: Array(all.values), headKeys: headKeys,
      summary: ScanSummary(
        complete: true, scanned: all.count, total: total,
        listRequests: requests, seconds: ProcessInfo.processInfo.systemUptime - started,
        checkedAt: now, reason: reason))
  }
}
