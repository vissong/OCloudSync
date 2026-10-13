#!/usr/bin/env python3
"""Exercise the actual scan method with delayed/failing page responses, offline."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/OCloudSync/WebSession.swift").read_text()
def extract(signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]

method = extract("  func scan(\n")
navigation = "\n".join(extract(signature) for signature in [
    "  func webView(_ view: WKWebView, didStartProvisionalNavigation",
    "  func webView(_ view: WKWebView, didCommit",
])
harness = r'''
import Foundation
final class WKWebView {
  let url = URL(string: "https://cloud.oppo.com/module.html")
  var bridgeRetirements = 0
  var released = false
  func evaluateJavaScript(_ script: String, completionHandler: ((Any?, Error?) -> Void)?) {
    precondition(["window.OCloudBridge?.retire(true)", "window.OCloudBridge?.retire(false)"].contains(script))
    released = script.contains("true")
    bridgeRetirements += 1
  }
}
final class WKNavigation {}
struct Ledger {}
struct ScanPage {}
struct ScanResult { let account = "fixture" }
struct Marker { let serial: Int }
enum Request { case begin, next, page(Int) }
struct TimedOut: Error {}
@MainActor enum AlbumScanner {
  static func scan(ledger: Ledger, forceFull: Bool, pendingAccounts: Set<String>,
    load: (Request) async throws -> ScanPage, progress: (Int, Int) -> Void
  ) async throws -> ScanResult {
    _ = try await load(.begin)
    return ScanResult()
  }
}
@MainActor final class SessionSpy {
  enum Outcome { case success, cancelled, timeout, navigated, provisionalCancelled, woke, loggedOut }
  let webView = WKWebView()
  var outcome: Outcome
  var session = SessionLease()
  var documentGeneration: UInt64 = 0
  var needsRescan = true
  var requiresLogin: Bool { session.state == .loginRequired }
  var prepared = 0
  var retired = 0
  init(_ outcome: Outcome) {
    self.outcome = outcome
    let id = session.begin(at: Date())!
    session.finish(SessionReply(kind: .active), id: id, at: Date())
  }
  func ensureSession() async throws { try Task.checkCancellation() }
  func installBridge() async throws {}
  func prepareFreshList() async throws { prepared += 1 }
  func evaluate<T>(_ expression: String, as: T.Type) async throws -> T {
    Marker(serial: 1) as! T
  }
  func wait(after serial: Int) async throws -> ScanPage {
    switch outcome {
    case .cancelled: throw CancellationError()
    case .timeout: throw TimedOut()
    case .navigated:
      webView(webView, didStartProvisionalNavigation: nil)
      webView(webView, didCommit: nil)
    case .provisionalCancelled:
      webView(webView, didStartProvisionalNavigation: nil) // Old document remains until commit.
    case .woke: session.wakeUp()
    case .loggedOut: session.pageChanged(loginRequired: true)
    case .success: break
    }
    return ScanPage()
  }
  func resetSession(loginRequired: Bool) {
    retired += 1
    session.pageChanged(loginRequired: loginRequired)
  }
  func publishSession() {}
__METHOD__
__NAVIGATION__
}
@main struct Regression {
  @MainActor static func main() async throws {
    for outcome in [SessionSpy.Outcome.cancelled, .timeout, .woke, .provisionalCancelled] {
      let spy = SessionSpy(outcome)
      do { _ = try await spy.scan(progress: { _, _ in }); fatalError("failed scan succeeded") } catch {}
      guard spy.retired == (outcome == .provisionalCancelled ? 2 : 1), spy.session.needsPageReload,
            spy.session.state == .retrying, spy.needsRescan else {
        print("FAIL: failed scan page can accept a late response on the next scan: \(outcome)")
        exit(1)
      }
      precondition(spy.webView.bridgeRetirements == 1 && !spy.webView.released)
      // A renewal cannot make the abandoned document usable before it reloads.
      guard spy.session.begin(at: Date().addingTimeInterval(360)) == nil else {
        fatalError("abandoned page renewed without reloading")
      }
    }
    for outcome in [SessionSpy.Outcome.navigated, .loggedOut] {
      let spy = SessionSpy(outcome)
      do { _ = try await spy.scan(progress: { _, _ in }); fatalError("stale scan succeeded") } catch {}
      guard spy.retired == (outcome == .navigated ? 1 : 0), !spy.session.needsPageReload else {
        fatalError("old scan retired a new document or replaced login-required state")
      }
      precondition(spy.webView.bridgeRetirements == (outcome == .navigated ? 0 : 1))
    }
    let success = SessionSpy(.success)
    _ = try await success.scan(progress: { _, _ in })
    precondition(success.webView.bridgeRetirements == 1 && success.webView.released, "successful scan must release request interception")
    guard success.retired == 0, !success.session.needsPageReload, !success.needsRescan else {
      fatalError("successful scan retired the usable page")
    }
    print("PASS: interrupted/timed-out scans retire the old document; navigation, login and success preserved")
  }
}
'''.replace("__METHOD__", method).replace("__NAVIGATION__", navigation)
with tempfile.TemporaryDirectory(prefix="ocloud-scan-retirement-") as folder:
    swift = Path(folder) / "Regression.swift"
    binary = Path(folder) / "regression"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-parse-as-library", str(root / "Sources/SyncCore/SessionLease.swift"), str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
