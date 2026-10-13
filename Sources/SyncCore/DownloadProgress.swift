import Foundation

/// Ephemeral progress for the current original-file download; never persisted in the ledger.
public struct DownloadProgress: Equatable {
  public let filename: String
  public let receivedBytes: Int64
  public let totalBytes: Int64
  public let bytesPerSecond: Double?

  public init(filename: String, receivedBytes: Int64 = 0, totalBytes: Int64,
    bytesPerSecond: Double? = nil) {
    self.filename = filename
    self.receivedBytes = max(0, receivedBytes)
    self.totalBytes = max(0, totalBytes)
    self.bytesPerSecond = bytesPerSecond
  }

  public var fractionCompleted: Double? {
    guard totalBytes > 0 else { return nil }
    return min(1, Double(receivedBytes) / Double(totalBytes))
  }
}

/// Rolling byte rate. Callers supply monotonic timestamps, including ticks with no new data.
public struct DownloadSpeedMeter {
  private var samples: [(time: TimeInterval, bytes: Int64)] = []
  private let window: TimeInterval = 3
  public init() {}

  public mutating func sample(bytes: Int64, at time: TimeInterval) -> Double? {
    guard bytes >= 0, time.isFinite else { samples.removeAll(); return nil }
    if let last = samples.last,
      time <= last.time || time - last.time > window || bytes < last.bytes {
      samples.removeAll()
    }
    samples.append((time, bytes))
    // Retain the sample just before the window boundary for a stable rate.
    while samples.count > 2, samples[1].time <= time - window { samples.removeFirst() }
    guard let first = samples.first, time - first.time >= 0.25 else { return nil }
    return Double(bytes - first.bytes) / (time - first.time)
  }
}

/// Poll Progress on the main actor. Tokens isolate timers from cancelled or subsequent downloads.
@MainActor public final class DownloadProgressMonitor {
  public var onUpdate: ((DownloadProgress?) -> Void)?
  private var token: UUID?
  private var snapshot: DownloadProgress?
  private var meter = DownloadSpeedMeter()
  private var task: Task<Void, Never>?

  public init() {}
  deinit { task?.cancel() }

  public func begin(token: UUID, filename: String, totalBytes: Int64) {
    task?.cancel()
    task = nil
    self.token = token
    meter = DownloadSpeedMeter()
    snapshot = DownloadProgress(filename: filename, totalBytes: totalBytes)
    onUpdate?(snapshot)
  }

  public func observe(_ progress: Progress, token: UUID) {
    guard self.token == token else { return }
    task?.cancel()
    meter = DownloadSpeedMeter()
    poll(progress, token: token)
    task = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
        guard !Task.isCancelled else { return }
        self?.poll(progress, token: token)
      }
    }
  }

  private func poll(_ progress: Progress, token: UUID) {
    guard self.token == token, let previous = snapshot else { return }
    let received = max(0, progress.completedUnitCount)
    let speed = meter.sample(bytes: received, at: ProcessInfo.processInfo.systemUptime)
    snapshot = DownloadProgress(filename: previous.filename, receivedBytes: received,
      totalBytes: previous.totalBytes > 0 ? previous.totalBytes : progress.totalUnitCount,
      bytesPerSecond: speed)
    onUpdate?(snapshot)
  }

  public func end(token: UUID) {
    guard self.token == token else { return }
    task?.cancel()
    task = nil
    self.token = nil
    snapshot = nil
    meter = DownloadSpeedMeter()
    onUpdate?(nil)
  }
}
