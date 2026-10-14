import AppKit
import SwiftUI
import SyncCore
import WebKit

@main struct OCloudSyncApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model = AppModel()
  var body: some Scene {
    WindowGroup("OPPO 照片同步") { Dashboard(model: model).frame(minWidth: 960, minHeight: 700) }
      .windowStyle(.titleBar)
      .commands { CommandGroup(replacing: .newItem) {} }
    MenuBarExtra("OPPO 照片同步", systemImage: "arrow.triangle.2.circlepath.icloud") {
      Text(model.syncHeadline)
      Button("显示同步窗口") {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title == "OPPO 照片同步" })?.makeKeyAndOrderFront(nil)
      }
      Button("立即扫描") { model.run() }.disabled(model.busy)
      Button("完整核对") { model.run(forceFull: true) }.disabled(model.busy)
      Button(model.enabled ? "停止自动同步" : "启用自动同步") { model.setEnabled(!model.enabled) }
      Divider()
      Button("退出") { NSApp.terminate(nil) }
    }
  }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
struct BrowserView: NSViewRepresentable {
  let webView: WKWebView
  func makeNSView(context: Context) -> WKWebView { webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}
struct Dashboard: View {
  @ObservedObject var model: AppModel
  @State private var tab = 0
  @State private var checkFilename = ""
  private let accent = Color(red: 0.13, green: 0.45, blue: 0.36)
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 24) {
        HStack(spacing: 10) {
          Image(systemName: "arrow.triangle.2.circlepath.icloud.fill").font(.system(size: 28))
            .foregroundStyle(accent)
          Text("照片同步").font(.title2.weight(.semibold))
        }.padding(.top, 12)
        VStack(spacing: 6) {
          nav("同步概览", icon: "square.grid.2x2", index: 0)
          nav("导入队列", icon: "list.bullet.clipboard", index: 4)
          nav("OPPO 登录", icon: "person.crop.circle", index: 1)
          nav("任务记录", icon: "list.bullet.rectangle", index: 2)
          nav("按时间导入", icon: "calendar", index: 3)
        }
        Spacer()
        VStack(alignment: .leading, spacing: 8) {
          Label("自动同步新增照片与视频", systemImage: "sparkles")
          Text("关闭窗口后继续运行\n退出 App 后停止同步").font(.caption).foregroundStyle(.secondary)
        }
        Text("本地版本 0.8.1").font(.caption2).foregroundStyle(.tertiary)
      }.padding(24).frame(width: 185).background(Color(nsColor: .controlBackgroundColor))
      Divider()
      VStack(alignment: .leading, spacing: 20) {
        if tab == 1 {
          HStack {
            VStack(alignment: .leading) {
              Text("连接 OPPO 云相册").font(.title.weight(.semibold))
              Text("在官方页面完成登录，验证码由你本人确认。登录状态仅保留在这台 Mac。").foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新打开登录页") { model.web.login() }.disabled(model.busy)
          }
          sessionStatus
          BrowserView(webView: model.web.webView).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            .allowsHitTesting(!model.busy)
          HStack {
            Text(model.busy ? "同步中，登录页面暂不可操作" : "登录成功后可继续同步；已有历史基线和导入记录会保留。").font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("返回概览") { tab = 0 }
          }
        } else if tab == 4 {
          ImportQueueView(model: model)
        } else if tab == 3 {
          RangeImportView(model: model)
        } else if tab == 2 {
          Text("任务记录").font(.largeTitle.weight(.semibold))
          Text("历史基线 \(model.baseline) 项。下方列出自动同步及手动导入记录。").foregroundStyle(.secondary)
          HStack {
            TextField("输入完整文件名，单独检查下载与查重", text: $checkFilename)
            Button("检查原文件") { model.checkOne(filename: checkFilename) }.disabled(
              model.busy || checkFilename.isEmpty || model.fatal != nil)
          }
          Text(model.status).font(.caption).foregroundStyle(.secondary)
          if let progress = model.downloadProgress { DownloadProgressView(progress: progress) }
          VStack(alignment: .leading, spacing: 8) {
            HStack {
              Button("检查拍摄时间") { model.checkDates() }.disabled(model.busy || model.fatal != nil)
              if let preview = model.datePreview, !preview.items.isEmpty {
                Button("修复 \(preview.items.count) 项日期") { model.repairDates() }
                  .disabled(model.busy || model.fatal != nil)
              }
            }
            Text(model.dateStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let preview = model.datePreview, !preview.items.isEmpty {
              ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                  ForEach(preview.items) { item in
                    Text("\(item.filename)：\(item.before?.formatted() ?? "无日期") → \(item.target.date.formatted())")
                      .font(.caption).textSelection(.enabled)
                  }
                }.frame(maxWidth: .infinity, alignment: .leading)
              }.frame(maxHeight: 100)
            }
          }
          records
        } else {
          HStack {
            VStack(alignment: .leading, spacing: 6) {
              Text("让原图，自动抵达。").font(.system(size: 30, weight: .semibold))
              Text("OPPO 云相册 → 这台 Mac → iCloud 照片").foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40, weight: .light))
              .foregroundStyle(accent)
          }
          HStack(spacing: 14) {
            metric("历史基线", value: model.baseline)
            metric("已导入图库", value: model.imported)
            metric("重复已跳过", value: model.duplicates)
            metric("失败待处理", value: model.failures)
          }
          VStack(alignment: .leading, spacing: 16) {
            HStack {
              Circle().fill(model.busy ? Color.orange : model.enabled ? accent : .gray).frame(
                width: 8, height: 8)
              Text(model.syncHeadline).font(.headline)
              Spacer()
              if model.busy { ProgressView().controlSize(.small) }
            }
            sessionStatus
            Text(model.status).textSelection(.enabled).frame(
              maxWidth: .infinity, alignment: .leading)
            if let progress = model.downloadProgress { DownloadProgressView(progress: progress) }
            if let check = model.ledger.lastCheck {
              Text(check.label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let progress = model.localRecoveryProgress {
              ImportProgressView(progress: progress, label: "本地恢复")
            }
            if let progress = model.importProgress {
              ImportProgressView(progress: progress)
            } else if model.busy && model.total > 0 {
              ProgressView(value: Double(model.completed), total: Double(model.total))
              Text("正在检查 \(model.completed) / \(model.total)").font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            HStack {
              Button(model.enabled ? "停止自动同步" : "启用自动同步") { model.setEnabled(!model.enabled) }
                .buttonStyle(.borderedProminent).tint(accent).disabled(model.fatal != nil)
              Button("立即扫描") { model.run() }.disabled(model.busy || model.fatal != nil)
              Button("完整核对") { model.run(forceFull: true) }.disabled(
                model.busy || model.fatal != nil)
              Button("重试失败任务") { model.retry() }.disabled(
                model.busy || model.failures == 0 || model.fatal != nil)
              Spacer()
              Picker(
                "扫描间隔",
                selection: Binding(get: { model.intervalMinutes }, set: { model.setInterval($0) })
              ) { ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) 分钟").tag($0) } }.frame(
                width: 170)
            }
          }.padding(22).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
          VStack(alignment: .leading, spacing: 16) {
            setupRow("1", "登录 OPPO", "使用官方账号、短信或扫码流程，过期后可重新登录。", "打开登录页") { tab = 1 }
            Divider()
            setupRow("2", "允许访问照片图库", "用于核对重复原片，并将新增照片和视频导入系统图库。", "授权照片访问") { model.authorize() }
            Divider()
            setupRow("3", "检查 iCloud 照片", "请在“照片”设置中启用 iCloud；逐项上传状态由系统管理。", "打开照片") {
              model.openPhotos()
            }
          }.padding(20).background(
            Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
          HStack {
            Text(
              "照片与视频首次启用时分别建立历史基线。支持 JPEG / HEIC / PNG、OPPO JPEG 实况，以及 MP4 / MOV / M4V 视频。\n视频原文件直接导入，不转码；已下载原文件保留在本机缓存，云端文件不会被删除。"
            ).font(
              .caption
            ).foregroundStyle(.secondary)
            Spacer()
            Button("查看原文件缓存") { model.revealCache() }
          }
          Spacer(minLength: 0)
        }
      }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onChange(of: tab) { value in
      if value == 3 { model.rangePageOpen = true }
      else { model.leaveRangePage() }
    }
    .onChange(of: model.showQueue) { value in
      if value { tab = 4; model.showQueue = false }
    }
    .onChange(of: model.showLogin) { value in
      if value { tab = 1; model.showLogin = false }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { event in
      guard let window = event.object as? NSWindow, window.title == "OPPO 照片同步" else { return }
      model.leaveRangePage()
      tab = 0
    }
    .onDisappear { model.leaveRangePage() }
  }
  private var sessionStatus: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(model.session.state.label).foregroundStyle(
        model.session.state == .active ? accent : .secondary)
      if let time = model.session.lastSuccess {
        Text("最近会话验证：\(time.formatted(date: .omitted, time: .standard))")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private func nav(_ text: String, icon: String, index: Int) -> some View {
    Button {
      tab = index
    } label: {
      Label(text, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(
          tab == index ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.plain).disabled(model.busy && index == 3)
  }
  private func metric(_ title: String, value: Int) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value.formatted()).font(.system(size: 28, weight: .medium, design: .rounded))
    }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(
      Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
  }
  private func setupRow(
    _ n: String, _ title: String, _ text: String, _ button: String, action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 14) {
      Text(n).font(.headline).foregroundStyle(accent).frame(width: 28, height: 28).background(
        accent.opacity(0.1), in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.headline)
        Text(text).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button(button, action: action).disabled(model.busy)
    }
  }
  private var records: some View {
    List(model.visibleRecords) { r in
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(r.asset.filename).fontWeight(.medium)
          if let e = r.error {
            Text(e).font(.caption).foregroundStyle(.red)
          } else {
            Text(r.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
          }
          if let fallback = r.staticFallback {
            Text("实况转换失败，按静态照片处理：\(fallback.reason)").font(.caption).foregroundStyle(.orange)
          }
          if r.state == .duplicate, let reason = r.duplicateReason {
            Text(reason).font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          Text(r.resultLabel)
          if let time = r.nextAttempt {
            Text("下次重试 \(time.formatted(date: .omitted, time: .shortened))").font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }.overlay { if model.visibleRecords.isEmpty { Text("尚无新增任务").foregroundStyle(.secondary) } }
  }
}
