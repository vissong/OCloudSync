#!/usr/bin/env python3
"""Exercise production list waiting: service failure, auth, retry and cancellation."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/OCloudSync/WebSession.swift').read_text()
start = source.index('  func wait(after serial: Int)')
brace = source.index('{', start)
depth, end = 1, brace + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end]
harness = r'''
import Foundation
@MainActor final class ProcessInfo {
  static let processInfo = ProcessInfo()
  var systemUptime: TimeInterval = 0
}
struct ScanPage: Decodable { let ready: Bool }
struct SyncFailure: Error { let message: String; init(_ message: String) { self.message = message } }
enum State { case loginRequired }
struct SessionAccessFailure: Error { init(_ state: State) {} }
@MainActor final class Spy {
  var state: String
  var readyAfter: Int
  var reads = 0
  var stateReads = 0
  var advanceReadBy: TimeInterval = 0
  var cancelRead = false
  var loginRequired = false
  var messages = [String]()
  lazy var onScanMessage: ((String) -> Void)? = { [weak self] in self?.messages.append($0) }
  init(_ state: String, readyAfter: Int = Int.max) { self.state = state; self.readyAfter = readyAfter; ProcessInfo.processInfo.systemUptime = 0 }
  func resetSession(loginRequired: Bool) { self.loginRequired = loginRequired }
  func evaluate<T: Decodable>(_ expression: String, as: T.Type, timeout: TimeInterval = 5) async throws -> T {
    precondition(timeout > 0 && timeout <= 45)
    let json: String
    if expression.contains("requestState") { stateReads += 1; json = state }
    else { ProcessInfo.processInfo.systemUptime += advanceReadBy; if cancelRead { withUnsafeCurrentTask { $0?.cancel() } }; reads += 1; json = reads >= readyAfter ? "{\"ready\":true}" : "null" }
    return try JSONDecoder().decode(T.self, from: Data(json.utf8))
  }
__METHOD__
}
@main struct Regression {
  @MainActor static func main() async throws {
    let rejected = Spy("{\"kind\":\"failed\",\"code\":400,\"retries\":3,\"activity\":7}")
    do { _ = try await rejected.wait(after: 4); fatalError("expected failure") }
    catch let e as SyncFailure {
      precondition(e.message.contains("400") && e.message.contains("3 次"))
      precondition(!e.message.contains("超时") && rejected.reads == 1)
    }
    let expired = Spy("{\"kind\":\"loginRequired\",\"code\":403,\"retries\":0,\"activity\":1}")
    do { _ = try await expired.wait(after: 4); fatalError("expected auth failure") }
    catch is SessionAccessFailure { precondition(expired.loginRequired && expired.reads == 1) }
    let retry = Spy("{\"kind\":\"retrying\",\"retries\":1,\"activity\":2,\"code\":400,\"retryInSeconds\":15}", readyAfter: 2)
    precondition(try await retry.wait(after: 4).ready)
    precondition(retry.reads == 2 && retry.stateReads == 1)
    precondition(retry.messages.count == 2 && retry.messages[0].contains("15 秒后重试（1/3）"))
    precondition(retry.messages[0].contains("400"))
    precondition(retry.messages[1].contains("重试成功"))
    for seconds in [46.0, 361.0] {
      let late = Spy("null", readyAfter: 1)
      late.advanceReadBy = seconds
      do { _ = try await late.wait(after: 4); fatalError("late successful reply accepted") }
      catch let e as SyncFailure { precondition(e.message.contains("超时")) }
    }
    let cancelledReply = Spy("null", readyAfter: 1)
    cancelledReply.cancelRead = true
    let cancelledResult = Task { @MainActor in try await cancelledReply.wait(after: 4) }
    do { _ = try await cancelledResult.value; fatalError("cancelled reply accepted") }
    catch is CancellationError {}
    let cancelled = Spy("null")
    let work = Task { @MainActor in try await cancelled.wait(after: 4) }
    work.cancel()
    do { _ = try await work.value; fatalError("expected cancellation") }
    catch is CancellationError { precondition(cancelled.reads == 0) }
    print("PASS: list failure returns promptly, auth is distinct, bounded retry can complete, cancellation starts no read")
  }
}
'''.replace('__METHOD__', method).replace('precondition(try await retry.wait(after: 4).ready)', 'let page = try await retry.wait(after: 4); precondition(page.ready)')
with tempfile.TemporaryDirectory(prefix='ocloud-list-wait-') as folder:
    swift = Path(folder) / 'Regression.swift'
    binary = Path(folder) / 'regression'
    swift.write_text(harness)
    subprocess.run(['swiftc', '-parse-as-library', str(root / 'Sources/SyncCore/ListRequestWait.swift'), str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)


# Exercise the production JSON callback deadline, including a late completion.
def extract(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

callback_harness = r"""
import Foundation
enum State { case retrying }
struct SessionAccessFailure: Error { init(_ state: State) {} }
@MainActor final class WebView {
  var completion: ((Any?, Error?) -> Void)?
  var calls = 0
  var immediate = false
  func evaluateJavaScript(_ expression: String, completionHandler: @escaping (Any?, Error?) -> Void) {
    calls += 1
    completion = completionHandler
    if immediate { completionHandler("true", nil) }
  }
}
@MainActor final class ScriptSpy {
  let webView = WebView()
  func run(timeout: TimeInterval = 0.02) async throws -> String {
    try await sessionJSON("true", timeout: timeout)
  }
__JSON__
}
__RESULT__
@main struct CallbackDeadline {
  @MainActor static func main() async throws {
    let hung = ScriptSpy()
    do { _ = try await hung.run(); fatalError("missing deadline") }
    catch is SessionAccessFailure {}
    hung.webView.completion?("late", nil) // Must not resume the timed-out continuation twice.
    await Task.yield()
    let interrupted = ScriptSpy()
    let pending = Task { @MainActor in try await interrupted.run(timeout: 1) }
    while interrupted.webView.calls == 0 { await Task.yield() }
    pending.cancel() // Cancellation after evaluation has started must resume immediately.
    let started = Date()
    do { _ = try await pending.value; fatalError("cancelled script succeeded") }
    catch is CancellationError { precondition(Date().timeIntervalSince(started) < 0.5) }
    interrupted.webView.completion?("late", nil)
    await Task.yield()
    let ready = ScriptSpy()
    ready.webView.immediate = true
    let value = try await ready.run()
    precondition(value == "true")
    let cancelled = ScriptSpy()
    let work = Task { @MainActor in try await cancelled.run() }
    work.cancel()
    do { _ = try await work.value; fatalError("cancelled script started") }
    catch is CancellationError { precondition(cancelled.webView.calls == 0) }
    print("PASS: stalled JavaScript has a bounded deadline; late callbacks are ignored; cancellation starts no script")
  }
}
""".replace('__JSON__', extract('  private func sessionJSON(')).replace(
    '__RESULT__', extract('@MainActor\nprivate final class SessionScriptResult'))
with tempfile.TemporaryDirectory(prefix='ocloud-script-deadline-') as folder:
    swift = Path(folder) / 'Deadline.swift'
    binary = Path(folder) / 'deadline'
    swift.write_text(callback_harness)
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
