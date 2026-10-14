import Foundation

/// Uses monotonic uptime. Polling a retry countdown alone is not progress.
public struct ListRequestWait {
  private let startedAt: TimeInterval
  private var lastActivityAt: TimeInterval
  private var lastActivity = 0

  public init(startedAt: TimeInterval) {
    self.startedAt = startedAt
    self.lastActivityAt = startedAt
  }

  public mutating func observe(activity: Int, at now: TimeInterval) {
    guard activity > lastActivity else { return }
    lastActivity = activity
    lastActivityAt = now
  }

  public func hasTimedOut(at now: TimeInterval) -> Bool {
    remaining(at: now) <= 0
  }

  public func remaining(at now: TimeInterval) -> TimeInterval {
    max(0, min(360 - (now - startedAt), 45 - (now - lastActivityAt)))
  }
}
