import AppKit
import SwiftUI
import SyncCore

@MainActor final class AppModel: ObservableObject {
  @Published var ledger = Ledger()
  @Published var status = "登录 OPPO 后，建立新增照片同步基线"
  @Published var busy = false
  @Published var enabled = false
  @Published var showLogin = false
  @Published var session = SessionLease()
  @Published var fatal: String?
  @Published var completed = 0
  @Published var total = 0
  @Published var intervalMinutes = 15
  let web = WebSession()
  private var store: LedgerStore?
  private var importer: PhotoImporter?
  private var work: Task<Void, Never>?
  private var timer: Timer?
  private var activeAccount: String?
  private var cache: URL?
  private var nextScan = Date.distantPast
  private let defaults = UserDefaults.standard
  init() {
    do {
      let root = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("OCloudSync", isDirectory: true)
      let s = try LedgerStore(directory: root)
      store = s
      ledger = try s.load()
      if !ledger.records.isEmpty { status = "历史基线与导入记录已恢复，等待检查" }
      ledger.recoverInterrupted()
      try s.save(ledger)
      cache = root.appendingPathComponent("originals", isDirectory: true)
      try FileManager.default.createDirectory(
        at: cache!, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      importer = try PhotoImporter(
        directory: root.appendingPathComponent("imports", isDirectory: true))
      enabled = defaults.bool(forKey: "syncEnabled")
      let saved = defaults.integer(forKey: "scanMinutes")
      intervalMinutes = [5, 15, 30, 60].contains(saved) ? saved : 15
      web.onMessage = { [weak self] message in self?.status = message }
      web.diagnosticsURL = root.appendingPathComponent("session-status.json")
      web.onSessionChange = { [weak self] value in
        guard let self else { return }
        if self.session.state != .active && value.state == .active { self.nextScan = .distantPast }
        self.session = value
      }
      web.setKeepAlive(enabled)
      timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.tick() }
      }
    } catch {
      fatal = "无法打开同步台账：\(error.localizedDescription)"
      status = fatal!
    }
  }
  var visibleRecords: [SyncRecord] {
    ledger.records.values.filter { $0.state != .baseline }.sorted { $0.updatedAt > $1.updatedAt }
  }
  var imported: Int { ledger.records.values.filter { $0.state == .imported }.count }
  var duplicates: Int { ledger.records.values.filter { $0.state == .duplicate }.count }
  var baseline: Int { ledger.records.values.filter { $0.state == .baseline }.count }
  var failures: Int {
    ledger.records.values.filter {
      $0.state == .failed || ($0.state == .importing && $0.error != nil)
    }.count
  }
  func setEnabled(_ value: Bool) {
    enabled = value
    defaults.set(value, forKey: "syncEnabled")
    web.setKeepAlive(value)
    if value {
      nextScan = .distantPast
      run()
    } else {
      work?.cancel()
      status = "自动同步已停止；已导入的照片会继续由系统同步"
    }
  }
  func setInterval(_ value: Int) {
    intervalMinutes = value
    defaults.set(value, forKey: "scanMinutes")
    nextScan = Date().addingTimeInterval(Double(value) * 60)
  }
  func authorize() {
    Task {
      do {
        try await importer?.authorize()
        status = "照片图库访问已授权"
      } catch { status = error.localizedDescription }
    }
  }
  func revealCache() { if let cache { NSWorkspace.shared.open(cache) } }
  func openPhotos() {
    NSWorkspace.shared.openApplication(
      at: URL(fileURLWithPath: "/System/Applications/Photos.app"),
      configuration: NSWorkspace.OpenConfiguration())
  }
  /// Read-only end-to-end check; it never changes the baseline or imports a file.
  func checkOne(filename: String) {
    guard !busy, fatal == nil, !filename.trimmingCharacters(in: .whitespaces).isEmpty else {
      return
    }
    busy = true
    work = Task {
      defer {
        busy = false
        work = nil
      }
      do {
        status = "正在查找指定照片或视频…"
        let scan = try await web.scan { n, t in
          self.completed = n
          self.total = t
        }
        let matches = scan.assets.filter {
          $0.filename.caseInsensitiveCompare(filename.trimmingCharacters(in: .whitespaces))
            == .orderedSame
        }
        guard matches.count == 1, let a = matches.first else {
          throw SyncFailure("找到 \(matches.count) 个同名文件，请使用唯一文件名")
        }
        guard a.supported, let importer, let cache else { throw SyncFailure("该文件类型暂不支持单张检查") }
        status = "正在下载原文件进行检查…"
        let part = cache.appendingPathComponent(a.key + ".part." + (a.filename as NSString).pathExtension.lowercased())
        _ = try await web.download(a, to: part)
        let hash = try await importer.validate(part, asset: a)
        let file = cache.appendingPathComponent(
          a.key + "." + (a.filename as NSString).pathExtension.lowercased())
        if FileManager.default.fileExists(atPath: file.path) {
          try FileManager.default.removeItem(at: file)
        }
        try FileManager.default.moveItem(at: part, to: file)
        try Task.checkCancellation()
        status = "下载已校验，正在检查图库中是否存在相同原片…"
        let id: String?
        var liveManifest: LivePhotoManifest?
        if a.isMotionJPEG {
          status = "正在转换并校验 Live Photo 配对…"
          let pair = try await LivePhotoConverter.prepare(file, asset: a, hash: hash)
          liveManifest = pair.manifest
          id = try await importer.findExistingLive(filename: a.filename, manifest: pair.manifest)
        } else {
          id = try await importer.findExisting(
            asset: a, hash: hash)
        }
        struct Check: Codable {
          let filename: String
          let bytes: Int64
          let sha256: String
          let duplicateInPhotos: Bool
          let checkedAt: Date
          let livePhoto: LivePhotoManifest?
        }
        if let store {
          try JSONEncoder().encode(
            Check(
              filename: a.filename, bytes: a.bytes, sha256: hash, duplicateInPhotos: id != nil,
              checkedAt: Date(), livePhoto: liveManifest)
          ).write(to: store.directory.appendingPathComponent("last-check.json"), options: .atomic)
        }
        status =
          id != nil ? "检查通过：图库中已有相同原片／Live Photo 配对；没有再次导入" : "检查通过：原文件完整，实况配对已校验（如适用）；本次仅检查，未导入"
      } catch is CancellationError { status = "检查已停止" } catch {
        status = error.localizedDescription
      }
    }
  }
  func retry() {
    guard !busy else { return }
    var changed = ledger
    changed.retryFailures()
    do {
      try persist(changed)
      run()
    } catch { stopForStorage(error) }
  }
  var syncHeadline: String {
    if !enabled { return "自动同步已停止" }
    switch session.state {
    case .active: return "自动同步已启用"
    case .unknown: return "正在验证 OPPO 会话"
    case .loginRequired: return "等待重新登录"
    case .retrying: return "等待连接恢复"
    case .unsupported: return "等待接口恢复"
    }
  }
  private func tick() {
    guard enabled, fatal == nil else { return }
    web.maintainSession()
    guard !busy, session.state == .active else { return }
    if Date() >= nextScan
      || (activeAccount != nil && !ledger.due(at: Date(), account: activeAccount).isEmpty)
    {
      run()
    }
  }
  func run(forceFull: Bool = false) {
    guard !busy, fatal == nil else { return }
    busy = true
    work = Task { [weak self] in
      guard let self else { return }
      defer {
        self.busy = false
        self.work = nil
      }
      do {
        try await self.recoverLocalWork()
        self.status = "正在读取 OPPO 云相册…"
        self.completed = 0
        self.total = 0
        let pending = Set(self.ledger.due(at: Date()).map { $0.asset.account })
        let result = try await self.web.scan(
          ledger: self.ledger, forceFull: forceFull,
          pendingAccounts: pending
        ) { n, total in
          self.completed = n
          self.total = total
        }
        try Task.checkCancellation()
        let account = result.account
        let assets = result.assets
        let isBaseline = !self.ledger.accounts.contains(account)
        var updated = self.ledger
        try updated.applyScan(result)
        try self.persist(updated)
        self.activeAccount = account
        self.nextScan = Date().addingTimeInterval(Double(self.intervalMinutes) * 60)
        if !result.complete {
          self.status = "轻量检查完成，总数与首批无变化；每日完整核对其余照片"
          return
        }
        if isBaseline {
          self.status = "基线已建立：\(assets.count) 项历史文件；此后只同步新增照片"
          return
        }
        let present = Set(assets.map(\.key))
        let queue = self.ledger.due(at: Date(), account: account)
        guard !queue.isEmpty else {
          self.status = "扫描完成，没有新增照片"
          return
        }
        guard let importer = self.importer, let cache = self.cache else {
          throw SyncFailure("本地缓存不可用")
        }
        try importer.checkPermission()
        self.total = queue.count
        self.completed = 0
        for record in queue {
          try Task.checkCancellation()
          self.status = "正在处理：\(record.asset.filename)"
          do {
            try await self.process(
              record, importer: importer, cache: cache, sourceAvailable: present.contains(record.id)
            )
          } catch is CancellationError { throw CancellationError() } catch {
            try self.recordFailure(error, for: record)
          }
          self.completed += 1
          if self.web.needsRescan { break }
          try await Task.sleep(nanoseconds: 1_200_000_000)
        }
        self.status = "本轮完成。导入结果已保存；iCloud 上传进度请在“照片”中查看"
      } catch is CancellationError {
        var recovered = self.ledger
        recovered.recoverInterrupted()
        do { try self.persist(recovered) } catch { self.stopForStorage(error) }
        self.status = "已停止；任务进度已保留"
      } catch {
        if error is SessionAccessFailure {
          var recovered = self.ledger
          recovered.recoverInterrupted()
          do { try self.persist(recovered) } catch { self.stopForStorage(error) }
        }
        self.status = error.localizedDescription
        // Scan/authentication failures do not create a tight retry loop.
        self.nextScan = Date().addingTimeInterval(Double(self.intervalMinutes) * 60)
        self.activeAccount = nil
      }
    }
  }
  private func recoverLocalWork() async throws {
    guard let importer, let cache, (try? importer.checkPermission()) != nil else { return }
    for record in ledger.due(at: Date()) {
      let file = cache.appendingPathComponent(
        record.id + "." + (record.asset.filename as NSString).pathExtension.lowercased())
      guard record.state == .importing || FileManager.default.fileExists(atPath: file.path) else {
        continue
      }
      try Task.checkCancellation()
      status = "正在恢复本地任务：\(record.asset.filename)"
      do {
        try await process(record, importer: importer, cache: cache, sourceAvailable: nil)
      } catch is CancellationError { throw CancellationError() } catch {
        try recordFailure(error, for: record)
      }
    }
  }
  private func recordFailure(_ error: Error, for record: SyncRecord) throws {
    if fatal != nil { throw error }
    // Preserve a confirmed non-commit even if login expiration or cancellation happens concurrently.
    if error is ConfirmedImportFailure {
      var failed = ledger.records[record.id] ?? record
      failed.fail(error.localizedDescription, importWasNotCommitted: true)
      try save(failed)
      try Task.checkCancellation()
      if web.requiresLogin { throw SessionAccessFailure(.loginRequired) }
      return
    }
    try Task.checkCancellation()
    if let failure = error as? SessionAccessFailure { throw failure }
    if web.requiresLogin { throw SessionAccessFailure(.loginRequired) }
    var failed = ledger.records[record.id] ?? record
    failed.fail(error.localizedDescription)
    try save(failed)
  }
  private func process(
    _ input: SyncRecord, importer: PhotoImporter, cache: URL, sourceAvailable: Bool?
  ) async throws {
    var r = input
    // Reconcile the local identifier from either ledger or pre-commit journal.
    let receipt = try importer.receipt(for: r.id)
    if let id = r.photoID ?? receipt?.photoID, importer.exists(id) {
      if r.asset.isMotionJPEG {
        guard let manifest = r.livePhoto ?? receipt?.livePhoto else {
          throw SyncFailure("缺少 Live Photo 配对回执，暂停重复导入")
        }
        try await importer.verifyLiveAsset(id, manifest: manifest)
        r.livePhoto = manifest
        r.sha256 = manifest.sourceHash
      }
      if r.asset.isVideo {
        guard let hash = r.sha256 ?? receipt?.sourceHash else {
          throw SyncFailure("缺少视频原文件校验回执，暂停重复导入")
        }
        try await importer.verifyOriginalVideo(id, hash: hash)
        r.sha256 = hash
      }
      r.photoID = id
      r.state = .imported
      r.error = nil
      try save(r)
      return
    }
    if r.asset.isMotionJPEG && r.state == .importing {
      if let manifest = r.livePhoto ?? receipt?.livePhoto,
        let id = try await importer.findExistingLive(filename: r.asset.filename, manifest: manifest)
      {
        r.photoID = id
        r.livePhoto = manifest
        r.sha256 = manifest.sourceHash
        r.state = .imported
        r.error = nil
        r.nextAttempt = nil
        try save(r)
        return
      }
      throw SyncFailure("上次 Live Photo 导入结果尚未确认，保留回执并暂停重复导入；重试会先核对图库")
    }
    if r.asset.isVideo && r.state == .importing {
      if let hash = r.sha256 ?? receipt?.sourceHash,
        let id = try await importer.findExisting(asset: r.asset, hash: hash)
      {
        r.photoID = id; r.sha256 = hash; r.state = .imported
        r.error = nil; r.nextAttempt = nil
        try save(r)
        return
      }
      throw SyncFailure("上次视频导入结果尚未确认，保留回执并暂停重复导入；重试会先核对图库")
    }
    let file = cache.appendingPathComponent(
      r.id + "." + (r.asset.filename as NSString).pathExtension.lowercased())
    var hash: String?
    if FileManager.default.fileExists(atPath: file.path) {
      do { hash = try await importer.validate(file, asset: r.asset) }
      catch is CancellationError { throw CancellationError() } catch {}
    }
    if hash == nil {
      guard sourceAvailable == true else {
        // nil means local recovery has not checked the remote inventory yet.
        r.deferMissingOriginal(sourceIsAbsent: sourceAvailable == false)
        try save(r)
        return
      }
      r.state = .downloading
      try save(r)
      let part = cache.appendingPathComponent(r.id + ".part." + (r.asset.filename as NSString).pathExtension.lowercased())
      _ = try await web.download(r.asset, to: part)
      try Task.checkCancellation()
      hash = try await importer.validate(part, asset: r.asset)
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
      try FileManager.default.moveItem(at: part, to: file)
    }
    r.sha256 = hash
    r.state = .downloaded
    try save(r)
    guard let hash else { throw SyncFailure("无法计算文件校验值") }
    try Task.checkCancellation()
    if r.asset.isMotionJPEG {
      status = "正在转换实况照片：\(r.asset.filename)"
      let pair = try await LivePhotoConverter.prepare(file, asset: r.asset, hash: hash)
      r.livePhoto = pair.manifest
      try save(r)
      for match in ledger.duplicates(hash: hash, excluding: r.id, account: r.asset.account) {
        if let id = match.photoID, let manifest = match.livePhoto, importer.exists(id) {
          try await importer.verifyLiveAsset(id, manifest: manifest)
          r.photoID = id
          r.livePhoto = manifest
          r.state = .duplicate
          r.error = nil
          try save(r)
          return
        }
      }
      if let id = try await importer.findExistingLive(
        filename: r.asset.filename, manifest: pair.manifest)
      {
        r.photoID = id
        r.state = .duplicate
        r.error = nil
        try save(r)
        return
      }
      try Task.checkCancellation()
      status = "正在将 Live Photo 配对导入图库…"
      r.state = .importing
      try save(r)
      r.photoID = try await importer.importLive(pair, asset: r.asset)
      r.state = .imported
      r.error = nil
      r.nextAttempt = nil
      try save(r)
      return
    }
    if let id = ledger.duplicates(hash: hash, excluding: r.id, account: r.asset.account)
      .compactMap(\.photoID).first(where: { importer.exists($0) })
    {
      if r.asset.isVideo { try await importer.verifyOriginalVideo(id, hash: hash) }
      r.photoID = id
      r.state = .duplicate
      r.error = nil
      try save(r)
      return
    }
    if let id = try await importer.findExisting(
      asset: r.asset, hash: hash)
    {
      r.photoID = id
      r.state = .duplicate
      r.error = nil
      try save(r)
      return
    }
    try Task.checkCancellation()
    r.state = .importing
    try save(r)
    let id = try await importer.importFile(file, asset: r.asset, hash: hash)
    r.photoID = id
    r.state = .imported
    r.error = nil
    r.nextAttempt = nil
    try save(r)
  }
  private func save(_ record: SyncRecord) throws {
    var changed = ledger
    var r = record
    r.updatedAt = Date()
    changed.records[r.id] = r
    try persist(changed)
  }
  private func persist(_ changed: Ledger) throws {
    do {
      guard let store else { throw SyncFailure("台账不可用") }
      try store.save(changed)
      ledger = changed
    } catch {
      stopForStorage(error)
      throw error
    }
  }
  private func stopForStorage(_ error: Error) {
    fatal = "台账写入失败，已停止导入：\(error.localizedDescription)"
    enabled = false
    web.setKeepAlive(false)
    defaults.set(false, forKey: "syncEnabled")
  }
}
