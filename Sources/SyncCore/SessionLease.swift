import Foundation

public enum SessionState: String, Codable, Sendable {
  case unknown, active, loginRequired, retrying, unsupported
  public var label: String {
    switch self {
    case .unknown: return "OPPO 会话待验证"
    case .active: return "OPPO 会话有效"
    case .loginRequired: return "OPPO 登录已失效，请重新登录；云端同步已暂停"
    case .retrying: return "OPPO 连接暂不可用，稍后自动重试"
    case .unsupported: return "OPPO 续期接口未通过校验，请重新打开登录页或更新程序"
    }
  }
}
public struct SessionReply: Codable, Sendable {
  public let kind: SessionState
  public let code: Int?
  public init(kind: SessionState, code: Int? = nil) {
    self.kind = kind
    self.code = code
  }
}
/// Metadata only. Never stores account IDs, URLs, cookies or tokens.
public struct SessionLease: Codable, Sendable {
  public private(set) var state: SessionState = .unknown
  public private(set) var lastSuccess: Date?
  public private(set) var nextAttempt: Date?
  public private(set) var failureCount = 0
  public private(set) var successCount = 0
  public private(set) var responseCode: Int?
  public private(set) var attempt: UUID?
  public private(set) var needsPageReload = false
  public private(set) var pageGeneration: UInt64 = 0
  private var lastCommittedPath: String?
  public init() {}
  public mutating func interrupt() {
    attempt = nil
    nextAttempt = nil
  }
  public mutating func wakeUp() {
    attempt = nil
    pageGeneration &+= 1
    // Waking is not a navigation: keep pending page recovery and its cooldown.
    if state == .active {
      state = .unknown
      nextAttempt = nil
    }
  }
  public mutating func pageChanged(loginRequired: Bool, userInitiated: Bool = false) {
    if userInitiated { lastCommittedPath = nil }
    pageGeneration &+= 1
    needsPageReload = false
    attempt = nil
    // The official 401 handler navigates to index.html. That redirect is not a retry request.
    if !loginRequired, !userInitiated, state == .unsupported { return }
    nextAttempt = nil
    if loginRequired || userInitiated { failureCount = 0 }
    state = loginRequired ? .loginRequired : .unknown
  }
  public mutating func begin(at now: Date) -> UUID? {
    guard attempt == nil, state != .loginRequired, !needsPageReload else { return nil }
    if let nextAttempt, now < nextAttempt, nextAttempt.timeIntervalSince(now) <= 300 { return nil }
    let id = UUID()
    attempt = id
    return id
  }
  public func canReloadPage(at now: Date, downloadInProgress: Bool) -> Bool {
    needsPageReload && !downloadInProgress
      && (nextAttempt.map { now >= $0 || $0.timeIntervalSince(now) > 300 } ?? true)
  }
  public func validatePage(_ generation: UInt64) throws {
    guard generation == pageGeneration else { throw SessionAccessFailure(.unknown) }
    guard state == .active else { throw SessionAccessFailure(state) }
  }
  public mutating func pageLoadFailed(at now: Date) {
    attempt = nil
    needsPageReload = true
    // A failed automatic redirect still needs a reload, even while 401 is cooling down.
    if let nextAttempt, now < nextAttempt, nextAttempt.timeIntervalSince(now) <= 300 { return }
    state = .retrying
    responseCode = nil
    failureCount += 1
    nextAttempt = now.addingTimeInterval(min(30 * pow(2, Double(min(failureCount - 1, 4))), 300))
  }
  /// The official client also sends non-renewal 401 errors from the album to its home page.
  /// Delay that return loop without assuming a particular HTTP status was observed.
  public mutating func pageCommitted(path: String?, at now: Date) -> Bool {
    let previous = lastCommittedPath
    lastCommittedPath = path
    guard previous == "/module.html", path == "/index.html" else { return false }
    attempt = nil
    needsPageReload = true
    state = .unsupported
    responseCode = nil
    failureCount = max(1, failureCount)
    if nextAttempt.map({ $0 > now && $0.timeIntervalSince(now) <= 300 }) != true {
      nextAttempt = now.addingTimeInterval(300)
    }
    return true
  }
  /// A file response can reject authorization before the next renewal observes it.
  public mutating func rejectDownload(statusCode: Int?) -> Bool {
    guard statusCode == 403 else { return false }
    pageChanged(loginRequired: true)
    responseCode = statusCode
    return true
  }
  public mutating func finish(_ reply: SessionReply, id: UUID, at now: Date, needsPageReload: Bool = false) {
    guard attempt == id else { return }
    attempt = nil
    self.needsPageReload = needsPageReload
    state = reply.kind
    responseCode = reply.code
    switch reply.kind {
    case .active:
      lastSuccess = now
      successCount += 1
      failureCount = 0
      nextAttempt = now.addingTimeInterval(60)
    case .loginRequired: nextAttempt = nil
    case .retrying, .unknown:
      failureCount += 1
      nextAttempt = now.addingTimeInterval(min(30 * pow(2, Double(min(failureCount - 1, 4))), 300))
    case .unsupported:
      failureCount += 1
      nextAttempt = now.addingTimeInterval(300)
    }
  }
}
public struct SessionAccessFailure: LocalizedError {
  public let state: SessionState
  public var errorDescription: String? { state.label }
  public init(_ state: SessionState) { self.state = state }
}
