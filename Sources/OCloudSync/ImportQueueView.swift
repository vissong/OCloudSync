import SwiftUI
import SyncCore

struct ImportQueueView: View {
  @ObservedObject var model: AppModel
  @State private var filter: QueueFilter = .all
  @State private var search = ""

  var body: some View {
    let batches = (model.ledger.importBatches ?? []).sorted { $0.createdAt > $1.createdAt }
    let batch = batches.first { $0.id == model.queueBatchID }
    let keys = batch?.recordKeys ?? Array(Set(batches.flatMap(\.recordKeys)))
    let summary = model.ledger.queueSummary(keys: keys,activeKey: model.processingKey)
    let records = model.ledger.queueRecords(batchID: model.queueBatchID)
    let visible = records.filter {
      filter.includes($0) && (search.isEmpty || $0.asset.filename.localizedCaseInsensitiveContains(search))
    }
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Text("导入队列").font(.largeTitle.weight(.semibold))
        Spacer()
        if model.busy { Button("停止同步") { model.setEnabled(false) } }
        else {
          Button("继续全部队列") { model.run() }.disabled(model.ledger.queueSummary(keys: batches.flatMap(\.recordKeys)).remaining == 0 || model.fatal != nil)
          Button("重试全部失败任务") { model.retry() }.disabled(model.failures == 0 || model.fatal != nil)
        }
      }
      Text("文件清单和处理结果保存在这台 Mac，退出重开后可继续查看。")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading,spacing: 6) {
        Text(model.fatal ?? model.status)
          .foregroundStyle(model.fatal == nil ? Color.secondary : .red)
          .font(.callout).textSelection(.enabled)
        if model.session.state != .active {
          HStack {
            Label(model.session.state.label,systemImage: "network")
              .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if [.loginRequired,.unsupported].contains(model.session.state) {
              Button("前往 OPPO 登录") { model.showLogin = true }.disabled(model.busy)
            }
          }
        }
      }
      Picker("导入批次", selection: $model.queueBatchID) {
        Text("全部队列").tag(Optional<UUID>.none)
        ForEach(batches) { batch in
          Text("\(batch.title) · \(batch.recordKeys.count) 项").tag(Optional(batch.id))
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("已完成 \(summary.successful) / \(summary.total)").font(.headline)
          Spacer()
          Text("剩余 \(summary.remaining) 项").foregroundStyle(.secondary)
        }
        if summary.total > 0 {
          ProgressView(value: Double(summary.successful),total: Double(summary.total))
        }
        Text("已导入 \(summary.imported) · 重复 \(summary.duplicates) · 处理中 \(summary.active) · 等待 \(summary.waiting) · 失败 \(summary.failed) · 无法处理 \(summary.blocked)")
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        Text("完成数包含已导入和重复跳过；失败不计为完成。iCloud 上传由系统照片管理。")
          .font(.caption).foregroundStyle(.secondary)
      }.padding(16).background(Color(nsColor: .controlBackgroundColor),in: RoundedRectangle(cornerRadius: 10))
      if let progress = model.downloadProgress { DownloadProgressView(progress: progress) }
      HStack {
        Picker("状态",selection: $filter) {
          ForEach(QueueFilter.allCases,id: \.self) { Text($0.rawValue).tag($0) }
        }.frame(width: 210)
        TextField("搜索文件名",text: $search)
        Text("\(visible.count) 项").font(.caption).foregroundStyle(.secondary)
      }
      List(visible) { record in
        HStack(alignment: .top,spacing: 12) {
          Image(systemName: record.asset.isVideo ? "video" : record.asset.isMotionJPEG ? "livephoto" : "photo")
            .foregroundStyle(.secondary).frame(width: 22)
          VStack(alignment: .leading,spacing: 4) {
            Text(record.asset.filename).fontWeight(.medium).textSelection(.enabled)
            Text("\(record.asset.captureDate?.formatted(date: .numeric,time: .standard) ?? "拍摄时间待从原文件读取") · \(ByteCountFormatter.string(fromByteCount: record.asset.bytes,countStyle: .file))")
              .font(.caption).foregroundStyle(.secondary)
            if let warning = record.staticFallback {
              Text("实况转换失败，按静态照片处理：\(warning.reason)").font(.caption).foregroundStyle(.orange)
            }
            if let reason = record.duplicateReason, record.state == .duplicate {
              Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if let error = record.error { Text(error).font(.caption).foregroundStyle(.red) }
          }
          Spacer()
          VStack(alignment: .trailing,spacing: 4) {
            Text(model.processingKey == record.id ? "正在处理" : record.resultLabel).font(.caption)
            if [.failed,.importing].contains(record.state), let next = record.nextAttempt {
              Text("下次重试 \(next.formatted(date: .omitted,time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
          }
        }.padding(.vertical,4)
      }.overlay {
        if visible.isEmpty {
          Text(summary.total == 0 ? "队列为空。可在“按时间导入”中选择文件加入。" : "没有符合筛选条件的文件")
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
