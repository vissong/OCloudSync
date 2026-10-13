import SwiftUI
import SyncCore

struct DownloadProgressView: View {
  let progress: DownloadProgress

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("正在下载", systemImage: "arrow.down.circle")
        Text(progress.filename).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 12)
        Text(speedLabel).fontWeight(.medium).monospacedDigit().fixedSize()
      }
      if let fraction = progress.fractionCompleted {
        ProgressView(value: fraction)
      } else {
        ProgressView().controlSize(.small)
      }
      HStack {
        Text(sizeLabel).monospacedDigit()
        Spacer()
        if let fraction = progress.fractionCompleted {
          Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
        }
      }.foregroundStyle(.secondary)
    }.font(.caption)
      .accessibilityElement(children: .combine)
  }

  private var speedLabel: String {
    guard let speed = progress.bytesPerSecond else { return "等待下载…" }
    // Decimal units match the file-size display (1 MB = 1,000,000 bytes).
    if speed >= 1_000_000 { return String(format: "%.1f MB/s", speed / 1_000_000) }
    if speed >= 1_000 { return String(format: "%.1f KB/s", speed / 1_000) }
    return String(format: "%.0f B/s", speed)
  }

  private var sizeLabel: String {
    let received = ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)
    guard progress.totalBytes > 0 else { return "已下载 \(received)" }
    let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
    return "\(received) / \(total)"
  }
}
