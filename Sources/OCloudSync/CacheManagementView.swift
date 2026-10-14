import SwiftUI
import SyncCore

struct CacheManagementView: View {
  @ObservedObject var model: AppModel
  @State private var confirmClear = false
  private func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("原文件缓存").font(.headline)
        if model.cacheStatisticsBusy || model.clearingCache {
          ProgressView().controlSize(.small)
        } else if let stats = model.cacheStatistics {
          Text("\(stats.fileCount) 个文件 · 占用约 \(size(stats.allocatedBytes))")
            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            .help("文件大小合计 \(size(stats.logicalBytes))；磁盘占用为系统报告值，共享磁盘块可能影响实际释放空间。")
        } else { Text("尚未统计").foregroundStyle(.secondary) }
        Spacer()
        Button("刷新") { model.refreshCacheStatistics() }
          .disabled(model.cacheStatisticsBusy || model.clearingCache)
        Button("查看文件") { model.revealCache() }
        Button("清空缓存", role: .destructive) { confirmClear = true }
          .disabled(model.cacheCleanupBlockedReason != nil || model.cacheStatisticsBusy || model.cacheStatistics == nil || model.cacheStatistics?.entryCount == 0)
      }
      Text(model.cacheStatus.isEmpty
        ? model.cacheCleanupBlockedReason ?? "包含原文件、未完成下载和转换副本；清理后不会删除云端或照片图库中的内容。"
        : model.cacheStatus)
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }
    .task { model.refreshCacheStatistics() }
    .onChange(of: model.busy) { busy in
      if !busy && model.cacheStatus.isEmpty { model.refreshCacheStatistics() }
    }
    .alert("清空本机原文件缓存？", isPresented: $confirmClear) {
      Button("取消", role: .cancel) {}
      Button("清空缓存", role: .destructive) { model.clearOriginalCache() }
    } message: {
      Text("将删除本机下载的原文件、未完成下载和转换副本。照片图库、OPPO 云端内容、导入记录和登录状态会保留。尚未完成的任务需要重新下载；云端已删除的文件将无法恢复。")
    }
  }
}
