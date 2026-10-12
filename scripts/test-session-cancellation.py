#!/usr/bin/env python3
"""Exercise the real ensureSession body with an offline renewal spy."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Sources/OCloudSync/WebSession.swift").read_text()
start = source.index("  func ensureSession() async throws {")
brace = source.index("{", start)
depth = 1
end = brace + 1
while depth:
    depth += (source[end] == "{") - (source[end] == "}")
    end += 1
method = source[start:end]
harness = r'''
import Foundation
struct SessionAccessFailure: Error { init(_ state: State) {} }
enum State { case active }
@MainActor final class SessionSpy {
  let isLoginPage = false
  let requiresLogin = false
  let session = (state: State.active, unused: false)
  var requests = 0
  func resetSession(loginRequired: Bool) { fatalError("unexpected navigation") }
  func refreshSession() async {
    // Match the production ownership boundary: renewal is an independent task.
    let request = Task { @MainActor in self.requests += 1 }
    await request.value
  }
__METHOD__
}
@main struct Regression {
  @MainActor static func main() async throws {
    let stopped = SessionSpy()
    let queuedScan = Task { @MainActor in try await stopped.ensureSession() }
    queuedScan.cancel() // cancelled before the main actor can start the queued scan
    do { try await queuedScan.value; fatalError("cancellation not propagated") }
    catch is CancellationError {}
    guard stopped.requests == 0 else {
      print("FAIL: cancelled scan started \(stopped.requests) renewal request(s)")
      exit(1)
    }
    let manual = SessionSpy()
    try await manual.ensureSession()
    guard manual.requests == 1 else { fatalError("manual scan did not validate") }
    print("PASS: cancelled scan starts no renewal; explicit manual scan still validates")
  }
}
'''.replace("__METHOD__", method)
with tempfile.TemporaryDirectory(prefix="ocloud-session-cancel-") as folder:
    swift = Path(folder) / "Regression.swift"
    binary = Path(folder) / "regression"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
