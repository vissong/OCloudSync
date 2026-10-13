import SwiftUI
import SyncCore

struct ImportProgressView: View {
  let progress: ImportProgress
  var label = "本轮队列"

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if progress.total > 0 {
        ProgressView(value: Double(progress.processed), total: Double(progress.total))
      }
      Text("\(label)已处理 \(progress.processed) / \(progress.total) · 待处理 \(progress.remaining)")
      Text("已导入 \(progress.imported) · 重复 \(progress.duplicates) · 失败 \(progress.failed) · 延后 \(progress.deferred)")
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(.secondary)
    .help("此阶段的处理结果，包含失败和延后项。本地恢复与扫描后队列分开显示；不是历史累计成功数，也不是 iCloud 上传进度。")
  }
}
