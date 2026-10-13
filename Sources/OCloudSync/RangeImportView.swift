import SwiftUI
import SyncCore

struct RangeImportView: View {
  @ObservedObject var model: AppModel
  @State private var start = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
  @State private var end = Date()
  @State private var photos = true
  @State private var videos = true

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("按时间导入").font(.largeTitle.weight(.semibold))
      Text("按拍摄日期补充导入历史照片与视频，已导入或重复的文件会跳过。")
        .foregroundStyle(.secondary)
      HStack(spacing: 20) {
        DatePicker("开始日期", selection: $start, displayedComponents: .date)
        DatePicker("结束日期", selection: $end, displayedComponents: .date)
      }.disabled(model.busy)
      HStack(spacing: 24) {
        Toggle("照片（含实况）", isOn: $photos).toggleStyle(.checkbox)
        Toggle("视频", isOn: $videos).toggleStyle(.checkbox)
        Spacer()
        Button("预览范围") { model.previewRange(start: start, end: end, photos: photos, videos: videos) }
          .disabled(model.busy || model.fatal != nil || (!photos && !videos))
      }.disabled(model.busy)
      Text("包含起止日期全天 · 时区：\(model.rangePreview?.range.timeZoneIdentifier ?? TimeZone.current.identifier)")
        .font(.caption).foregroundStyle(.secondary)
      if model.busy {
        HStack {
          ProgressView().controlSize(.small)
          Text(model.rangeStatus).font(.caption).lineLimit(2)
          Spacer()
          if model.rangeImporting {
            Button("停止同步") { model.setEnabled(false) }
          } else {
            Button("取消预览") { model.cancelRangeWork() }
          }
        }
      } else {
        Text(model.rangeStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let progress = model.downloadProgress { DownloadProgressView(progress: progress) }
      if model.importProgressIsRange, let progress = model.importProgress {
        ImportProgressView(progress: progress)
      }
      if let preview = model.rangePreview {
        previewContent(preview)
      } else {
        Spacer()
        Text("预览只读取清单。勾选并点击导入后，才会下载原文件并写入系统照片图库。")
          .foregroundStyle(.secondary).frame(maxWidth: .infinity)
        Spacer()
      }
      Text("此页面打开时暂停启动自动任务。关闭后恢复原计划；停止同步后可在概览继续扫描或重试。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .onChange(of: start) { _ in model.clearRangePreview() }
    .onChange(of: end) { _ in model.clearRangePreview() }
    .onChange(of: photos) { _ in model.clearRangePreview() }
    .onChange(of: videos) { _ in model.clearRangePreview() }
  }

  private func previewContent(_ preview: DateRangePreview) -> some View {
    let eligible = preview.eligibleKeys(in: model.ledger)
    let selected = model.rangeSelected.intersection(eligible)
    let imageCount = preview.items.filter { $0.mediaType == 1 }.count
    let videoCount = preview.items.filter(\.isVideo).count
    let bytes = preview.items.filter { selected.contains($0.key) }.reduce(Int64(0)) { $0 + $1.bytes }
    var format = Date.FormatStyle(date: .numeric, time: .shortened)
    format.timeZone = TimeZone(identifier: preview.range.timeZoneIdentifier) ?? .current
    return VStack(alignment: .leading, spacing: 12) {
      Text("范围内 \(imageCount) 张照片、\(videoCount) 个视频 · 可导入 \(eligible.count) 项")
        .font(.headline)
      if preview.missingDateCount > 0 {
        Text("相册中另有 \(preview.missingDateCount) 项所选类型文件缺少有效拍摄时间，已排除；不会使用上传时间替代。")
          .font(.caption).foregroundStyle(.orange)
      }
      HStack {
        Button("全选可导入") { model.rangeSelected = eligible }
        Button("取消全选") { model.rangeSelected = [] }
        Spacer()
        Text("已选 \(selected.count) 项 · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
        Button("导入选中的 \(selected.count) 项") { model.importRange() }
          .buttonStyle(.borderedProminent).disabled(selected.isEmpty)
      }.disabled(model.busy)
      List(preview.items, id: \.key) { asset in
        let eligibility = preview.eligibility(asset, in: model.ledger)
        HStack {
          Toggle(isOn: Binding(get: { model.rangeSelected.contains(asset.key) }, set: { value in
            if value { model.rangeSelected.insert(asset.key) } else { model.rangeSelected.remove(asset.key) }
          })) {
            VStack(alignment: .leading, spacing: 3) {
              Text(asset.filename).lineLimit(1)
              Text("\(asset.captureDate!.formatted(format)) · \(asset.isVideo ? "视频" : asset.isMotionJPEG ? "实况照片" : "照片") · \(ByteCountFormatter.string(fromByteCount: asset.bytes, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            }
          }.toggleStyle(.checkbox).disabled(model.busy || eligibility != .ready)
          Spacer()
          Text(eligibility.rawValue).font(.caption).foregroundStyle(.secondary)
        }
      }.overlay { if preview.items.isEmpty { Text("该时间范围内没有匹配的照片或视频").foregroundStyle(.secondary) } }
    }
  }
}
