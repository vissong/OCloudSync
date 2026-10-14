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
  @Published var importProgress: ImportProgress?
  @Published var localRecoveryProgress: ImportProgress?
  @Published var importProgressIsRange = false
  @Published var downloadProgress: DownloadProgress?
  @Published var intervalMinutes = 15
  @Published var rangePreview: DateRangePreview?
  @Published var rangeStatus = "选择拍摄日期并预览，再勾选需要导入的文件"
  @Published var rangeSelected = Set<String>()
  @Published var rangePageOpen = false
  @Published var rangeImporting = false
  @Published var showQueue = false
  @Published var queueBatchID: UUID?
  @Published var processingKey: String?
  @Published var datePreview: PhotoDatePreview?
  @Published var dateStatus = "检查本 App 已导入项目的拍摄时间，再原位修复差异。"
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
      ledger.migrateStaticFallback()
      ledger.migrateImportQueue()
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
      web.onScanMessage = { [weak self] message in
        guard let self else { return }
        if self.rangePageOpen { self.rangeStatus = message }
        else { self.status = message }
      }
      web.downloadProgress.onUpdate = { [weak self] progress in self?.downloadProgress = progress }
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
    importProgress = nil
    localRecoveryProgress = nil
    importProgressIsRange = false
    completed = 0; total = 0
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
        status = "下载已校验，正在按文件名与拍摄时间检查图库…"
        let id = try importer.findExistingByNameAndDate(asset: a,file: file)
        var liveManifest: LivePhotoManifest?
        var staticFallback: StaticFallbackInfo?
        if a.isMotionJPEG && id == nil {
          status = "正在转换并校验 Live Photo 配对…"
          do {
            let pair = try await LivePhotoConverter.prepare(file, asset: a, hash: hash)
            liveManifest = pair.manifest
          } catch is CancellationError { throw CancellationError() }
          catch {
            try Task.checkCancellation()
            staticFallback = try await StaticPhotoFallback.prepare(file,asset: a,sourceHash: hash,
              reason: error.localizedDescription).info
          }
        }
        struct Check: Codable {
          let filename: String
          let bytes: Int64
          let sha256: String
          let duplicateInPhotos: Bool
          let checkedAt: Date
          let livePhoto: LivePhotoManifest?
          let staticFallback: StaticFallbackInfo?
        }
        if let store {
          try JSONEncoder().encode(
            Check(
              filename: a.filename, bytes: a.bytes, sha256: hash, duplicateInPhotos: id != nil,
              checkedAt: Date(), livePhoto: liveManifest,staticFallback: staticFallback)
          ).write(to: store.directory.appendingPathComponent("last-check.json"), options: .atomic)
        }
        status =
          id != nil ? "检查通过：图库中已有同文件名、同拍摄时间的同类型文件；没有再次导入"
            : staticFallback != nil ? "实况转换失败，但静态主图校验通过；本次仅检查，未导入"
            : "检查通过：原文件完整，实况配对已校验（如适用）；本次仅检查，未导入"
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
  func leaveRangePage() {
    guard rangePageOpen else { return }
    rangePageOpen = false
    clearRangePreview()
    // Closing the window cancels an unfinished preview, not an authorized import.
    if !rangeImporting { work?.cancel() }
  }
  func clearRangePreview() {
    rangePreview = nil
    rangeSelected = []
  }
  func previewRange(start: Date, end: Date, photos: Bool, videos: Bool) {
    guard !busy, fatal == nil else { return }
    clearRangePreview()
    let range: ImportDateRange
    do { range = try ImportDateRange(startDay: start, endDay: end) }
    catch { rangeStatus = error.localizedDescription; return }
    busy = true
    importProgress = nil
    localRecoveryProgress = nil
    importProgressIsRange = false
    completed = 0; total = 0
    work = Task {
      defer { busy = false; work = nil }
      do {
        rangeStatus = "正在读取完整清单，仅预览，不下载或导入…"
        let scan = try await web.scan(forceFull: true) { n, t in
          self.completed = n; self.total = t
          self.rangeStatus = "正在读取完整清单：\(n) / \(t) 项…"
        }
        try Task.checkCancellation()
        guard rangePageOpen else { return }
        let preview = try DateRangePreview(scan: scan, range: range, includePhotos: photos, includeVideos: videos)
        rangePreview = preview
        rangeSelected = preview.eligibleKeys(in: ledger)
        rangeStatus = "预览完成，尚未导入。确认勾选项后点击导入。"
      } catch is CancellationError { rangeStatus = "预览已取消" }
      catch { rangeStatus = error.localizedDescription }
    }
  }
  func importRange() {
    guard !busy, fatal == nil, let preview = rangePreview, !rangeSelected.isEmpty else { return }
    let selected = rangeSelected
    busy = true
    importProgress = nil
    localRecoveryProgress = nil
    importProgressIsRange = false
    completed = 0; total = 0
    rangeImporting = true
    work = Task {
      defer {
        status = fatal ?? rangeStatus
        busy = false; rangeImporting = false; work = nil
      }
      do {
        guard let importer, let cache else { throw SyncFailure("本地缓存不可用") }
        try importer.checkPermission()
        rangeStatus = "正在重新核对选中项目，准备导入…"
        let scan = try await web.scan(forceFull: true) { n, t in
          self.completed = n; self.total = t
          self.rangeStatus = "导入前核对清单：\(n) / \(t) 项…"
        }
        try Task.checkCancellation()
        var changed = ledger
        let keys = try changed.queueRangeImport(preview, selectedKeys: selected, freshScan: scan)
        try persist(changed)
        queueBatchID = changed.importBatches?.last?.id
        showQueue = true
        clearRangePreview()
        activeAccount = scan.account
        // A manual range import must not drain unrelated automatic or historical tasks.
        let queue = try keys.map { key in
          guard let record = ledger.records[key] else { throw SyncFailure("导入任务记录缺失") }
          return record
        }
        try await processQueue(queue, importer: importer, cache: cache,
          present: Set(scan.assets.map(\.key)), isRange: true)
        let done = keys.filter { [.imported, .duplicate].contains(ledger.records[$0]!.state) }.count
        rangeStatus = "本次已导入或跳过重复 \(done) / \(keys.count) 项。其余进度已保留，可在同步概览继续扫描或重试。iCloud 上传由系统照片管理。"
        status = rangeStatus
      } catch is CancellationError {
        var recovered = ledger; recovered.recoverInterrupted()
        do { try persist(recovered) } catch { stopForStorage(error) }
        clearRangePreview()
        rangeStatus = "已停止，任务进度已保留；可在同步概览继续扫描或重试"
      } catch {
        if error is SessionAccessFailure {
          var recovered = ledger; recovered.recoverInterrupted()
          do { try persist(recovered) } catch { stopForStorage(error) }
        }
        clearRangePreview()
        rangeStatus = error.localizedDescription
      }
    }
  }
  func cancelRangeWork() {
    work?.cancel()
    clearRangePreview()
  }
  func checkDates() {
    guard !busy, fatal == nil, let importer, let cache else { return }
    busy = true
    importProgress = nil
    localRecoveryProgress = nil
    importProgressIsRange = false
    completed = 0; total = 0
    datePreview = nil
    let records = ledger.records.values.filter { $0.state == .imported }.sorted { $0.id < $1.id }
    work = Task {
      defer { busy = false; work = nil }
      do {
        datePreview = try await importer.previewDates(records, cache: cache) { n, t in
          await MainActor.run { self.dateStatus = "正在核对图库日期：\(n) / \(t)…" }
        }
        guard let preview = datePreview else { return }
        dateStatus = "已检查 \(preview.checked) 项：\(preview.correct) 项日期正确，\(preview.items.count) 项待修复（视频 \(preview.items.filter(\.isVideo).count) 项），\(preview.skipped) 项因回执、日期来源或后续编辑而跳过。"
      } catch { dateStatus = error.localizedDescription }
    }
  }
  func repairDates() {
    guard !busy, fatal == nil, let importer, let preview = datePreview, !preview.items.isEmpty else { return }
    busy = true
    importProgress = nil
    localRecoveryProgress = nil
    importProgressIsRange = false
    completed = 0; total = 0
    datePreview = nil
    work = Task {
      defer { busy = false; work = nil }
      var repaired = 0
      do {
        _ = try importer.saveDateAudit(preview)
        for item in preview.items {
          try Task.checkCancellation()
          guard let record = ledger.records[item.key] else { throw SyncFailure("原导入记录缺失，请重新检查") }
          dateStatus = "正在修复拍摄时间：\(repaired + 1) / \(preview.items.count)…"
          try await importer.repairDate(item, record: record)
          if record.error != nil {
            var repairedRecord = record
            repairedRecord.error = nil
            try save(repairedRecord)
          }
          repaired += 1
        }
        dateStatus = "已原位修复 \(repaired) 项拍摄时间。原文件和图库标识保持不变，iCloud 更新由系统照片管理。"
      } catch {
        dateStatus = "已修复 \(repaired) 项，其余未完成：\(error.localizedDescription)。重新检查后可继续。"
      }
    }
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
    guard !busy, !rangePageOpen, session.state == .active else { return }
    if Date() >= nextScan
      || (activeAccount != nil && !ledger.due(at: Date(), account: activeAccount).isEmpty)
    {
      run()
    }
  }
  func run(forceFull: Bool = false) {
    guard !busy, fatal == nil else { return }
    busy = true
    importProgress = nil
    localRecoveryProgress = nil
    importProgressIsRange = false
    completed = 0; total = 0
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
        if isBaseline && self.ledger.due(at: Date(), account: account).isEmpty {
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
        try await self.processQueue(queue, importer: importer, cache: cache, present: present)
        self.status = self.web.needsRescan
          ? "本轮已暂停，需重新扫描；任务进度已保留"
          : "本轮处理结束，结果见下方明细；iCloud 上传进度请在“照片”中查看"
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
    let records = ledger.due(at: Date()).filter { record in
      let file = cache.appendingPathComponent(
        record.id + "." + (record.asset.filename as NSString).pathExtension.lowercased())
      return record.state == .importing || FileManager.default.fileExists(atPath: file.path)
    }
    if !records.isEmpty { localRecoveryProgress = ImportProgress(total: records.count) }
    for record in records {
      try Task.checkCancellation()
      status = "正在恢复本地任务：\(record.asset.filename)"
      do {
        try await process(record, importer: importer, cache: cache, sourceAvailable: nil)
      } catch is CancellationError { throw CancellationError() } catch {
        try recordFailure(error, for: record) {
          if let state = self.ledger.records[record.id]?.state {
            self.localRecoveryProgress?.finish(key: record.id, state: state)
          }
        }
      }
      if let state = ledger.records[record.id]?.state {
        localRecoveryProgress?.finish(key: record.id, state: state)
      }
    }
  }
  private func recordFailure(
    _ error: Error, for record: SyncRecord, onRecorded: (() -> Void)? = nil
  ) throws {
    if fatal != nil { throw error }
    // The resources are already committed and verified; only their date needs repair.
    if let dateFailure = error as? DateVerificationPending {
      var committed = ledger.records[record.id] ?? record
      committed.photoID = dateFailure.photoID
      committed.state = .imported
      committed.nextAttempt = nil
      committed.error = dateFailure.localizedDescription
      try save(committed)
      onRecorded?()
      return
    }
    // Preserve a confirmed non-commit even if login expiration or cancellation happens concurrently.
    if error is ConfirmedImportFailure {
      var failed = ledger.records[record.id] ?? record
      failed.fail(error.localizedDescription, importWasNotCommitted: true)
      try save(failed)
      onRecorded?()
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
    onRecorded?()
  }
  private struct ValidatedOriginal: Sendable {
    let file: URL
    let hash: String
  }
  private struct PreparedQueueItem: Sendable {
    let key: String
    let original: ValidatedOriginal?
    let skip: Bool
  }
  /// One original can be downloaded ahead while the single consumer converts, deduplicates and imports.
  private func processQueue(
    _ records: [SyncRecord], importer: PhotoImporter, cache: URL, present: Set<String>,
    isRange: Bool = false
  ) async throws {
    total = records.count; completed = 0
    importProgress = ImportProgress(total: records.count)
    importProgressIsRange = isRange
    try await ImportPipeline.run(items: records,
      canPrepare: { !self.web.needsRescan && self.fatal == nil },
      prepare: { input in
        try Task.checkCancellation()
        let record = self.ledger.records[input.id] ?? input
        do {
          let receipt = try importer.receipt(for: record.id)
          let hasReceipt = (record.photoID ?? receipt?.photoID).map { importer.exists($0) } ?? false
          let uncertain = record.state == .importing
          if hasReceipt || uncertain {
            return PreparedQueueItem(key: record.id, original: nil, skip: false)
          }
          let original = try await self.prepareOriginal(record, importer: importer, cache: cache,
            sourceAvailable: present.contains(record.id))
          if original == nil { self.finishQueueItem(record.id) }
          return PreparedQueueItem(key: record.id, original: original, skip: original == nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
          try self.recordFailure(error, for: record) { self.finishQueueItem(record.id) }
          return PreparedQueueItem(key: record.id, original: nil, skip: true)
        }
      }, consume: { item in
        try Task.checkCancellation()
        guard self.fatal == nil else { throw SyncFailure(self.fatal!) }
        guard let record = self.ledger.records[item.key] else { throw SyncFailure("导入任务记录缺失") }
        if !item.skip {
          self.status = "正在处理：\(record.asset.filename)"
          if isRange { self.rangeStatus = self.status }
          do {
            // A consumer must never start a network request alongside the producer.
            try await self.process(record, importer: importer, cache: cache,
              sourceAvailable: nil, prepared: item.original)
          } catch is CancellationError { throw CancellationError() }
          catch {
            try self.recordFailure(error, for: record) { self.finishQueueItem(record.id) }
          }
        }
        self.finishQueueItem(item.key)
      })
  }
  private func finishQueueItem(_ key: String) {
    if let state = ledger.records[key]?.state {
      importProgress?.finish(key: key, state: state)
      completed = importProgress?.processed ?? 0
    }
  }
  private func prepareOriginal(
    _ input: SyncRecord, importer: PhotoImporter, cache: URL, sourceAvailable: Bool?
  ) async throws -> ValidatedOriginal? {
    var r = input
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
        return nil
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
    return ValidatedOriginal(file: file, hash: hash)
  }
  private func process(
    _ input: SyncRecord, importer: PhotoImporter, cache: URL, sourceAvailable: Bool?,
    prepared: ValidatedOriginal? = nil
  ) async throws {
    processingKey = input.id
    defer { processingKey = nil }
    var r = input
    // Reconcile the local identifier from either ledger or pre-commit journal.
    let receipt = try importer.receipt(for: r.id)
    r.staticFallback = r.staticFallback ?? receipt?.staticFallback
    r.videoCompatibility = r.videoCompatibility ?? receipt?.videoCompatibility
    if let id = r.photoID ?? receipt?.photoID, importer.exists(id) {
      if let fallback = r.staticFallback {
        try await importer.verifyStaticAsset(id,hash: fallback.stillHash)
        r.sha256 = fallback.sourceHash
        r.livePhoto = nil
      } else if r.asset.isMotionJPEG {
        guard let manifest = r.livePhoto ?? receipt?.livePhoto else {
          throw SyncFailure("缺少 Live Photo 配对回执，暂停重复导入")
        }
        try await importer.verifyLiveAsset(id, manifest: manifest)
        r.livePhoto = manifest
        r.sha256 = manifest.sourceHash
      }
      if r.asset.isVideo {
        guard let hash = r.videoCompatibility?.importHash ?? r.sha256 ?? receipt?.sourceHash else {
          throw SyncFailure("缺少视频原文件校验回执，暂停重复导入")
        }
        try await importer.verifyOriginalVideo(id, hash: hash)
        r.sha256 = r.videoCompatibility?.sourceHash ?? hash
      } else if !r.asset.isMotionJPEG {
        guard let hash = r.sha256 ?? receipt?.sourceHash else {
          throw SyncFailure("缺少照片原文件校验回执，暂停重复导入")
        }
        try await importer.verifyStaticAsset(id,hash: hash)
        r.sha256 = hash
      }
      if let date = receipt?.mediaDate, receipt?.dateVerified != true {
        try importer.confirmImportedDate(r.id, id: id, expected: date.date)
      }
      r.photoID = id
      r.state = .imported
      r.error = nil
      try save(r)
      return
    }
    if let fallback = r.staticFallback, r.state == .importing {
      if let id = try await importer.findExisting(asset: r.asset,hash: fallback.stillHash) {
        try await importer.verifyStaticAsset(id,hash: fallback.stillHash)
        r.photoID = id; r.sha256 = fallback.sourceHash; r.state = .imported
        r.livePhoto = nil; r.error = nil; r.nextAttempt = nil
        try save(r)
        return
      }
      throw SyncFailure("上次静态回退导入结果尚未确认，保留回执并暂停重复导入")
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
      if let hash = r.videoCompatibility?.importHash ?? r.sha256 ?? receipt?.sourceHash,
        let id = try await importer.findExisting(asset: r.asset, hash: hash)
      {
        r.photoID = id; r.sha256 = r.videoCompatibility?.sourceHash ?? hash; r.state = .imported
        r.error = nil; r.nextAttempt = nil
        try save(r)
        return
      }
      throw SyncFailure("上次视频导入结果尚未确认，保留回执并暂停重复导入；重试会先核对图库")
    }
    if r.state == .importing {
      if let hash = r.sha256 ?? receipt?.sourceHash,
        let id = try await importer.findExisting(asset: r.asset,hash: hash) {
        try await importer.verifyStaticAsset(id,hash: hash)
        r.photoID = id; r.sha256 = hash; r.state = .imported
        r.error = nil; r.nextAttempt = nil
        try save(r)
        return
      }
      throw SyncFailure("上次照片导入结果尚未确认，保留回执并暂停重复导入；重试会先核对图库")
    }
    let original: ValidatedOriginal?
    if let prepared { original = prepared }
    else { original = try await prepareOriginal(r, importer: importer, cache: cache, sourceAvailable: sourceAvailable) }
    guard let original else { return }
    let previousFallback = r.staticFallback
    r = ledger.records[r.id] ?? r
    r.staticFallback = r.staticFallback ?? previousFallback
    let file = original.file, hash = original.hash
    try Task.checkCancellation()
    if let id = try importer.findExistingByNameAndDate(asset: r.asset,file: file) {
      r.photoID = id
      r.state = .duplicate
      r.duplicateReason = "图库中已有同文件名、同拍摄时间的\(r.asset.isVideo ? "视频" : "照片")"
      r.error = nil; r.nextAttempt = nil
      try save(r)
      return
    }
    var fileToImport = file, assetToImport = r.asset, hashToImport = hash
    if r.asset.isVideo {
      status = "正在检查视频封装兼容性：\(r.asset.filename)"
      let video = try await VideoCompatibility.prepare(file, asset: r.asset, sourceHash: hash)
      r.videoCompatibility = video.info
      fileToImport = video.file; hashToImport = video.hash
      try save(r)
    }
    if r.asset.isMotionJPEG && r.staticFallback == nil {
      status = "正在转换实况照片：\(r.asset.filename)"
      let pair: PreparedLivePhoto?
      do { pair = try await LivePhotoConverter.prepare(file,asset: r.asset,hash: hash) }
      catch is CancellationError { throw CancellationError() }
      catch {
        try Task.checkCancellation()
        let fallback = try await StaticPhotoFallback.prepare(file,asset: r.asset,sourceHash: hash,
          reason: error.localizedDescription)
        r.staticFallback = fallback.info; r.livePhoto = nil
        try save(r)
        fileToImport = fallback.file; assetToImport = fallback.asset; hashToImport = fallback.info.stillHash
        pair = nil
      }
      if let pair {
        r.livePhoto = pair.manifest
        try save(r)
        try Task.checkCancellation()
        status = "正在将 Live Photo 配对导入图库…"
        r.state = .importing
        try save(r)
        r.photoID = try await importer.importLive(pair,asset: r.asset)
        r.state = .imported
        r.error = nil
        r.nextAttempt = nil
        try save(r)
        return
      }
    } else if let saved = r.staticFallback {
      let fallback = try await StaticPhotoFallback.prepare(file,asset: r.asset,sourceHash: hash,reason: saved.reason)
      r.staticFallback = fallback.info
      fileToImport = fallback.file; assetToImport = fallback.asset; hashToImport = fallback.info.stillHash
    }
    try Task.checkCancellation()
    r.state = .importing
    try save(r)
    if r.staticFallback != nil { status = "实况转换失败，正在按静态照片导入：\(r.asset.filename)" }
    let id = try await importer.importFile(fileToImport, asset: assetToImport, hash: hashToImport,
      staticFallback: r.staticFallback, videoCompatibility: r.videoCompatibility)
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
