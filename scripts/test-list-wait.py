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
struct ScanPage: Decodable { let ready: Bool }
struct SyncFailure: Error { let message: String; init(_ message: String) { self.message = message } }
enum State { case loginRequired }
struct SessionAccessFailure: Error { init(_ state: State) {} }
@MainActor final class Spy {
  var state: String
  var readyAfter: Int
  var reads = 0
  var stateReads = 0
  var loginRequired = false
  init(_ state: String, readyAfter: Int = Int.max) { self.state = state; self.readyAfter = readyAfter }
  func resetSession(loginRequired: Bool) { self.loginRequired = loginRequired }
  func evaluate<T: Decodable>(_ expression: String, as: T.Type) async throws -> T {
    let json: String
    if expression.contains("requestState") { stateReads += 1; json = state }
    else { reads += 1; json = reads >= readyAfter ? "{\"ready\":true}" : "null" }
    return try JSONDecoder().decode(T.self, from: Data(json.utf8))
  }
__METHOD__
}
@main struct Regression {
  @MainActor static func main() async throws {
    let rejected = Spy("{\"kind\":\"failed\",\"code\":400,\"retries\":2}")
    do { _ = try await rejected.wait(after: 4); fatalError("expected failure") }
    catch let e as SyncFailure {
      precondition(e.message.contains("400") && e.message.contains("2 次"))
      precondition(!e.message.contains("超时") && rejected.reads == 1)
    }
    let expired = Spy("{\"kind\":\"loginRequired\",\"code\":403,\"retries\":0}")
    do { _ = try await expired.wait(after: 4); fatalError("expected auth failure") }
    catch is SessionAccessFailure { precondition(expired.loginRequired && expired.reads == 1) }
    let retry = Spy("{\"kind\":\"retrying\",\"retries\":1}", readyAfter: 2)
    precondition(try await retry.wait(after: 4).ready)
    precondition(retry.reads == 2 && retry.stateReads == 1)
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
    subprocess.run(['swiftc', '-parse-as-library', str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=10)
