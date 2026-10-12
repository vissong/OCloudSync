import AppKit
import SyncCore
import WebKit

@MainActor
final class WebSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate,
  WKHTTPCookieStoreObserver
{
  let webView: WKWebView
  var onMessage: ((String) -> Void)?
  private(set) var needsRescan = false
  private var popups = [NSWindow]()
  private var pending: CheckedContinuation<URL, Error>?
  private var destination: URL?
  private var activeDownload: WKDownload?
  private var watchdog: Task<Void, Never>?
  private var gate = OperationGate()
  private var actionTokens = [ObjectIdentifier: UUID]()
  private var expectedFileID: String?
  private var cookieSave: Task<Void, Never>?
  private(set) var session = SessionLease()
  var onSessionChange: ((SessionLease) -> Void)?
  var diagnosticsURL: URL?
  private var keepAlive = false
  private var sessionTask: Task<Void, Never>?
  private var sessionJobID: UUID?
  private var wakeObserver: NSObjectProtocol?
  private var documentGeneration: UInt64 = 0
  var requiresLogin: Bool { session.state == .loginRequired }

  override init() {
    let c = WKWebViewConfiguration()
    c.websiteDataStore = .default()
    c.preferences.javaScriptCanOpenWindowsAutomatically = true
    webView = WKWebView(frame: .zero, configuration: c)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.keepAlive else { return }
        self.resetSession(loginRequired: self.isLoginPage, waking: true)
        self.maintainSession()
      }
    }
    Task { @MainActor in
      do {
        for cookie in try CookieVault.load() {
          await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
      } catch { onMessage?(error.localizedDescription) }
      webView.configuration.websiteDataStore.httpCookieStore.add(self)
      login()
    }
  }
  func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
    cookieSave?.cancel()
    cookieSave = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 400_000_000)
        let cookies = await cookieStore.allCookies()
        try Task.checkCancellation()
        try CookieVault.save(cookies)
      } catch is CancellationError {} catch { onMessage?(error.localizedDescription) }
    }
  }
  func login(retryNow: Bool = true) {
    if retryNow { resetSession(loginRequired: false, userInitiated: true) }
    webView.load(URLRequest(url: URL(string: "https://cloud.oppo.com/module.html#/photo")!))
  }
  func installBridge() async throws {
    guard webView.url?.host == "cloud.oppo.com" else { throw SyncFailure("请先在 OPPO 登录页完成登录") }
    let resources =
      Bundle.main.url(forResource: "OCloudSync_OCloudSync", withExtension: "bundle").flatMap(
        Bundle.init(url:)) ?? Bundle.module
    guard let url = resources.url(forResource: "bridge", withExtension: "js") else {
      throw SyncFailure("缺少网页适配器资源")
    }
    _ = try await webView.evaluateJavaScript(String(contentsOf: url))
  }
  func evaluate<T: Decodable>(_ expression: String, as: T.Type) async throws -> T {
    if requiresLogin || isLoginPage { throw SessionAccessFailure(.loginRequired) }
    let generation = session.pageGeneration
    try session.validatePage(generation)
    do {
      let value = try await webView.evaluateJavaScript("JSON.stringify(" + expression + ")")
      try session.validatePage(generation)
      guard let string = value as? String, let data = string.data(using: .utf8) else {
        throw SyncFailure("网页返回了无效数据")
      }
      return try JSONDecoder().decode(T.self, from: data)
    } catch is CancellationError { throw CancellationError() } catch let error as SessionAccessFailure {
      throw error
    } catch {
      throw SyncFailure("OPPO 页面未就绪、登录已过期或接口发生变化，请打开登录页检查后重试")
    }
  }
  private struct Marker: Decodable { let serial: Int }
  private struct ListPreparation: Decodable {
    let ticket: Int
    let kind: String?
    let code: Int?
  }
  private func prepareFreshList() async throws {
    let started = try await evaluate("window.OCloudBridge.prepare()", as: ListPreparation.self)
    for _ in 0..<90 {
      try Task.checkCancellation()
      let result = try await evaluate(
        "window.OCloudBridge.prepared(\(started.ticket))", as: ListPreparation.self)
      switch result.kind {
      case "ready": return
      case "loginRequired":
        resetSession(loginRequired: true)
        throw SessionAccessFailure(.loginRequired)
      case "pending": try await Task.sleep(nanoseconds: 500_000_000)
      default:
        let detail = result.code.map { "接口状态 \($0)" } ?? "页面接口暂不可用"
        throw SyncFailure("无法刷新 OPPO 下载清单（\(detail)），本次未使用旧清单，请稍后重试")
      }
    }
    resetSession(loginRequired: false)
    session.pageLoadFailed(at: Date())
    publishSession()
    throw SessionAccessFailure(.retrying)
  }
  func wait(after serial: Int) async throws -> ScanPage {
    for _ in 0..<90 {
      try Task.checkCancellation()
      if let page = try await evaluate(
        "window.OCloudBridge.read(\(serial))", as: ScanPage?.self)
      { return page }
      try await Task.sleep(nanoseconds: 500_000_000)
    }
    throw SyncFailure("OPPO 列表请求超时，本次不提交基线；稍后可重试")
  }
  func scan(
    ledger: Ledger = Ledger(), forceFull: Bool = false,
    pendingAccounts: Set<String> = [], progress: (Int, Int) -> Void
  ) async throws -> ScanResult {
    try await ensureSession()
    let generation = session.pageGeneration
    let document = documentGeneration
    var completed = false
    defer {
      // Retire late page callbacks after interruption, including wake-up without navigation.
      // A newer document or an already scheduled recovery must keep its own session state.
      if !completed, documentGeneration == document, !requiresLogin, !session.needsPageReload {
        resetSession(loginRequired: false)
        session.pageLoadFailed(at: Date())
        publishSession()
      }
    }
    try await installBridge()
    try session.validatePage(generation)
    try await prepareFreshList()
    try session.validatePage(generation)
    let result = try await AlbumScanner.scan(
      ledger: ledger, forceFull: forceFull,
      pendingAccounts: pendingAccounts,
      load: { request in
        try self.session.validatePage(generation)
        let expression: String
        switch request {
        case .begin: expression = "window.OCloudBridge.begin()"
        case .next: expression = "window.OCloudBridge.next()"
        case .page(let n): expression = "window.OCloudBridge.page(\(n))"
        }
        let marker = try await self.evaluate(expression, as: Marker.self)
        return try await self.wait(after: marker.serial)
      }, progress: progress)
    try session.validatePage(generation)
    try Task.checkCancellation()
    completed = true
    needsRescan = false
    return result
  }
  func download(_ asset: RemoteAsset, to url: URL) async throws -> URL {
    if requiresLogin || isLoginPage { throw SessionAccessFailure(.loginRequired) }
    guard session.state == .active else { throw SessionAccessFailure(session.state) }
    // Never reload here: a new page needs a fresh scan and bridge before using asset metadata.
    guard !needsRescan else { throw SessionAccessFailure(.unknown) }
    guard pending == nil else { throw SyncFailure("已有下载正在进行") }
    try Task.checkCancellation()
    let json = String(data: try JSONEncoder().encode(asset), encoding: .utf8)!
    let id = try gate.begin()
    destination = url
    expectedFileID = asset.fileID
    try? FileManager.default.removeItem(at: url)
    return try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation { continuation in
          pending = continuation
          watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: asset.isVideo ? 7_200_000_000_000 : 300_000_000_000)
            guard !Task.isCancelled, self?.gate.accepts(id) == true else { return }
            self?.cancelDownload(message: "下载超时，请稍后重试")
          }
          Task { [weak self] in
            guard self?.gate.accepts(id) == true else { return }
            do {
              _ = try await self?.webView.evaluateJavaScript(
                "window.OCloudBridge.download(\(json))")
            } catch {
              if self?.gate.accepts(id) == true { self?.cancelDownload(message: "无法开始下载，请重新登录或扫描") }
            }
          }
        }
      }, onCancel: { Task { @MainActor [weak self] in self?.cancelDownload(message: "同步已停止") } })
  }
  func cancelDownload(message: String, reload: Bool = true, failure: Error? = nil) {
    guard let token = gate.active else { return }
    gate.cancel(token)
    needsRescan = true
    // Retire the page's delayed signing/form callbacks before allowing another request.
    if reload { webView.reload() }
    if let download = activeDownload {
      download.cancel { [weak self] _ in
        Task { @MainActor in self?.finish(.failure(failure ?? SyncFailure(message)), token: token) }
      }
    } else {
      finish(.failure(failure ?? SyncFailure(message)), token: token)
    }
  }
  private func finish(_ result: Result<URL, Error>, token: UUID) {
    guard gate.finish(token) else { return }
    watchdog?.cancel()
    watchdog = nil
    activeDownload = nil
    actionTokens = actionTokens.filter { $0.value != token }
    let p = pending
    pending = nil
    destination = nil
    expectedFileID = nil
    p?.resume(with: result)
  }
  private func isVendorURL(_ url: URL) -> Bool {
    let host = url.host ?? ""
    return url.scheme == "https"
      && ["oppo.com", "heytap.com", "heytapmobi.com", "nearme.com.cn", "oppomobile.com"].contains {
        host == $0 || host.hasSuffix("." + $0)
      }
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    if let url = action.request.url {
      if url.path.hasSuffix("/download_file") {
        let fileID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(
          where: { $0.name == "fileId" })?.value
        if let token = gate.active, gate.accepts(token), fileID == expectedFileID, isVendorURL(url)
        {
          actionTokens[ObjectIdentifier(action)] = token
          decisionHandler(.download)
        } else {
          decisionHandler(.cancel)
        }
        return
      }
      if action.targetFrame?.isMainFrame != false && url.scheme != "about" {
        let host = url.host ?? ""
        let allowed = [
          "oppo.com", "heytap.com", "heytapmobi.com", "nearme.com.cn", "oppomobile.com",
        ]
        guard url.scheme == "https",
          allowed.contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else {
          onMessage?("已阻止离开 OPPO 登录服务的跳转")
          decisionHandler(.cancel)
          return
        }
      }
    }
    decisionHandler(.allow)
  }
  func webView(
    _ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload
  ) {
    guard let token = actionTokens.removeValue(forKey: ObjectIdentifier(navigationAction)),
      gate.accepts(token), activeDownload == nil
    else {
      download.cancel { _ in }
      return
    }
    activeDownload = download
    download.delegate = self
  }
  func download(
    _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
    completionHandler: @escaping (URL?) -> Void
  ) {
    guard download === activeDownload, let token = gate.active, gate.accepts(token) else {
      completionHandler(nil)
      return
    }
    if session.rejectDownload(statusCode: (response as? HTTPURLResponse)?.statusCode) {
      completionHandler(nil)
      // Publish before resuming the download task; this must not become a file retry.
      resetSession(loginRequired: true)
      return
    }
    guard let url = destination, let source = response.url, isVendorURL(source),
      (response as? HTTPURLResponse)?.statusCode == 200
    else {
      completionHandler(nil)
      cancelDownload(message: "原图下载返回异常状态，请重新登录或重试")
      return
    }
    completionHandler(url)
  }
  func downloadDidFinish(_ download: WKDownload) {
    if download === activeDownload, let token = gate.active, gate.accepts(token),
      let url = destination
    {
      finish(.success(url), token: token)
    }
  }
  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    if download === activeDownload, let token = gate.active, gate.accepts(token) {
      cancelDownload(message: "下载失败，请检查网络；原图将在重试时重新下载")
    }
  }
  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for action: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    let child = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 820, height: 680), configuration: configuration)
    child.navigationDelegate = self
    child.uiDelegate = self
    let w = NSWindow(
      contentRect: child.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered,
      defer: false)
    w.title = "OPPO 账号登录"
    w.contentView = child
    w.isReleasedWhenClosed = false
    popups.append(w)
    w.center()
    w.makeKeyAndOrderFront(nil)
    return child
  }
  func webViewDidClose(_ webView: WKWebView) {
    popups.first(where: { $0.contentView === webView })?.close()
  }
}

extension WebSession {
  private var isLoginPage: Bool {
    guard let url = webView.url else { return false }
    return url.host != "cloud.oppo.com" || url.path == "/login.html"
  }
  func setKeepAlive(_ enabled: Bool) {
    keepAlive = enabled
    if enabled {
      maintainSession()
    } else {
      sessionTask?.cancel()
      sessionTask = nil
      sessionJobID = nil
      session.interrupt()
      publishSession()
    }
  }
  func maintainSession() {
    guard keepAlive, !webView.isLoading, !requiresLogin else { return }
    if session.needsPageReload {
      _ = reloadSessionPageIfNeeded()
      return
    }
    guard webView.url != nil else { return }
    Task { @MainActor [weak self] in
      guard let self, self.keepAlive else { return }
      await self.refreshSession()
    }
  }
  private func reloadSessionPageIfNeeded() -> Bool {
    guard !webView.isLoading,
      session.canReloadPage(at: Date(), downloadInProgress: pending != nil)
    else { return false }
    login(retryNow: false)
    return true
  }
  private func publishSession() {
    onSessionChange?(session)
    if let diagnosticsURL {
      struct Snapshot: Encodable {
        let state: SessionState
        let lastSuccess: Date?, nextAttempt: Date?
        let successCount: Int, failureCount: Int
        let responseCode: Int?
        let backgroundRenewalEnabled: Bool
      }
      let value = Snapshot(
        state: session.state, lastSuccess: session.lastSuccess,
        nextAttempt: session.nextAttempt, successCount: session.successCount,
        failureCount: session.failureCount, responseCode: session.responseCode,
        backgroundRenewalEnabled: keepAlive)
      if let bytes = try? JSONEncoder().encode(value) {
        try? bytes.write(to: diagnosticsURL, options: .atomic)
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: diagnosticsURL.path)
      }
    }
  }
  private func resetSession(loginRequired: Bool, userInitiated: Bool = false, waking: Bool = false) {
    needsRescan = true
    sessionTask?.cancel()
    sessionTask = nil
    sessionJobID = nil
    if waking && !loginRequired {
      session.wakeUp()
    } else {
      session.pageChanged(loginRequired: loginRequired, userInitiated: userInitiated)
    }
    publishSession()
    if pending != nil {
      let state: SessionState = loginRequired ? .loginRequired : .unknown
      cancelDownload(message: state.label, reload: false, failure: SessionAccessFailure(state))
    }
  }
  func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard view === webView else { return }
    resetSession(loginRequired: false)
  }
  func webView(_ view: WKWebView, didCommit navigation: WKNavigation!) {
    guard view === webView else { return }
    documentGeneration &+= 1
    if session.pageCommitted(path: view.url?.path, at: Date()) {
      publishSession()
    }
  }
  func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
    guard view === webView else { return }
    if session.needsPageReload { maintainSession(); return }
    if isLoginPage {
      resetSession(loginRequired: true)
      return
    }
    // Official login may land on the home page before returning to the album.
    if view.url?.path == "/index.html" {
      login(retryNow: false)
      return
    }
    maintainSession()
  }
  private func pageFailed(_ view: WKWebView, error: Error) {
    guard view === webView, (error as NSError).code != NSURLErrorCancelled else { return }
    resetSession(loginRequired: false)
    session.pageLoadFailed(at: Date())
    publishSession()
  }
  func webView(
    _ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    pageFailed(view, error: error)
  }
  func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    pageFailed(view, error: error)
  }
  func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
    guard view === webView else { return }
    resetSession(loginRequired: false)
    if keepAlive { login(retryNow: false) }
  }
  func ensureSession() async throws {
    try Task.checkCancellation()
    if isLoginPage { resetSession(loginRequired: true) }
    if !requiresLogin { await refreshSession() }
    try Task.checkCancellation()
    guard session.state == .active else { throw SessionAccessFailure(session.state) }
  }
  private func sessionJSON(_ expression: String) async throws -> String {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
      let request = SessionScriptResult(continuation)
      request.timer = Task { @MainActor in
        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
        request.resolve(.failure(SessionAccessFailure(.retrying)))
      }
      webView.evaluateJavaScript("JSON.stringify(" + expression + ")") { value, error in
        Task { @MainActor in
          if let string = value as? String, error == nil {
            request.resolve(.success(string))
          } else {
            request.resolve(.failure(SessionAccessFailure(.retrying)))
          }
        }
      }
    }
  }
  private func refreshSession() async {
    guard !Task.isCancelled else { return }
    if session.needsPageReload {
      // Explicit scans may recover even when background renewal is disabled.
      guard reloadSessionPageIfNeeded() else { return }
      for _ in 0..<120 {
        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
        if !webView.isLoading { break }
      }
      guard !session.needsPageReload, !webView.isLoading else { return }
    }
    if let task = sessionTask {
      await task.value
      return
    }
    guard !webView.isLoading, webView.url != nil else { return }
    if isLoginPage {
      resetSession(loginRequired: true)
      return
    }
    guard let id = session.begin(at: Date()) else { return }
    sessionJobID = id
    let task = Task { @MainActor [weak self] in
      guard let self, !Task.isCancelled else { return }
      var reply = SessionReply(kind: .retrying)
      var reloadPage = true
      do {
        let resources =
          Bundle.main.url(forResource: "OCloudSync_OCloudSync", withExtension: "bundle")
          .flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = resources.url(forResource: "session", withExtension: "js") else {
          throw SessionAccessFailure(.unsupported)
        }
        // Native five-second evaluation limits and forty-second request deadline also work offscreen.
        _ = try await self.sessionJSON(
          "(()=>{" + (try String(contentsOf: url)) + ";return true})()")
        try Task.checkCancellation()
        struct Ticket: Decodable { let ticket: Int }
        let started = try JSONDecoder().decode(
          Ticket.self, from: Data((try await self.sessionJSON("window.OCloudSession.begin()")).utf8)
        )
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
          try Task.checkCancellation()
          let json = try await self.sessionJSON("window.OCloudSession.read(\(started.ticket))")
          if let value = try? JSONDecoder().decode(SessionReply.self, from: Data(json.utf8)) {
            reply = value
            reloadPage = false
            break
          }
          try await Task.sleep(nanoseconds: 500_000_000)
        }
      } catch is CancellationError { return } catch let error as SessionAccessFailure {
        reply = SessionReply(kind: error.state)
        reloadPage = error.state == .retrying
      } catch { reply = SessionReply(kind: .retrying) }
      guard !Task.isCancelled, self.sessionJobID == id else { return }
      self.session.finish(reply, id: id, at: Date(), needsPageReload: reloadPage)
      self.publishSession()
      if reply.kind == .active {
        do {
          try CookieVault.save(
            await self.webView.configuration.websiteDataStore.httpCookieStore.allCookies())
        } catch { self.onMessage?(error.localizedDescription) }
      } else if reply.kind == .loginRequired, self.pending != nil {
        self.cancelDownload(message: SessionState.loginRequired.label, reload: false,
                            failure: SessionAccessFailure(.loginRequired))
      } else if reloadPage, self.pending != nil {
        // Cancel before the delayed reload; an auth timeout must not consume a file retry.
        self.cancelDownload(message: SessionState.retrying.label, reload: false,
                            failure: SessionAccessFailure(.retrying))
      }
    }
    sessionTask = task
    await task.value
    if sessionJobID == id {
      sessionTask = nil
      sessionJobID = nil
    }
  }
}

@MainActor
private final class SessionScriptResult {
  private var continuation: CheckedContinuation<String, Error>?
  var timer: Task<Void, Never>?
  init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
  func resolve(_ result: Result<String, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    timer?.cancel()
    timer = nil
    continuation.resume(with: result)
  }
}
