import Foundation

/// Owns a single helper and its temporary directory until the child has exited.
public enum ConversionWorker {
  public static func run(_ process: Process, stage: URL, timeout: TimeInterval = 180) async throws {
    defer { try? FileManager.default.removeItem(at: stage) }
    try Task.checkCancellation()
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    do {
      while process.isRunning {
        try Task.checkCancellation()
        guard Date() < deadline else { throw SyncFailure("实况转换超时，原文件已保留，可重试") }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      try Task.checkCancellation()
    } catch {
      if process.isRunning { process.terminate() }
      let stop = Date().addingTimeInterval(2)
      while process.isRunning && Date() < stop {
        // A cancelled Task.sleep would spin here. This grace delay is uncancellable.
        await withCheckedContinuation { continuation in
          DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
        }
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      // Never release the serial conversion slot or remove files while the child writes.
      process.waitUntilExit()
      throw error
    }
  }
}
