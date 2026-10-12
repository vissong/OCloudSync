import XCTest

@testable import SyncCore

final class SessionTests: XCTestCase {
  let now = Date(timeIntervalSince1970: 1000)
  func testRenewalEveryMinuteAndOnlyOneAttempt() {
    var session = SessionLease()
    let id = session.begin(at: now)!
    XCTAssertNil(session.begin(at: now))
    session.finish(.init(kind: .active, code: 200), id: id, at: now)
    XCTAssertEqual(session.state, .active)
    XCTAssertNil(session.begin(at: now.addingTimeInterval(59)))
    XCTAssertNotNil(session.begin(at: now.addingTimeInterval(60)))
    XCTAssertEqual(session.successCount, 1)
  }
  func testLoginRequiredPausesUntilPageNavigation() {
    var session = SessionLease()
    let id = session.begin(at: now)!
    session.finish(.init(kind: .loginRequired, code: 403), id: id, at: now)
    XCTAssertNil(session.begin(at: now.addingTimeInterval(9999)))
    session.pageChanged(loginRequired: false)
    XCTAssertNotNil(session.begin(at: now))
    XCTAssertEqual(session.state, .unknown)
  }
  func testOldRenewalCannotOverrideLogoutOrNewPage() {
    var session = SessionLease()
    let id = session.begin(at: now)!
    session.pageChanged(loginRequired: true)
    session.finish(.init(kind: .active, code: 200), id: id, at: now)
    XCTAssertEqual(session.state, .loginRequired)
    XCTAssertEqual(session.successCount, 0)
  }
  func testNetworkBackoffAndSuccessfulRecovery() {
    var session = SessionLease()
    let first = session.begin(at: now)!
    session.finish(.init(kind: .retrying), id: first, at: now)
    XCTAssertEqual(session.nextAttempt, now.addingTimeInterval(30))
    let second = session.begin(at: now.addingTimeInterval(30))!
    session.finish(.init(kind: .retrying), id: second, at: now.addingTimeInterval(30))
    XCTAssertEqual(session.nextAttempt, now.addingTimeInterval(90))
    let third = session.begin(at: now.addingTimeInterval(90))!
    session.finish(.init(kind: .active, code: 200), id: third, at: now.addingTimeInterval(90))
    XCTAssertEqual(session.failureCount, 0)
    XCTAssertEqual(session.lastSuccess, now.addingTimeInterval(90))
  }
  func testTimedOutPageCannotReuseHungRequestUntilReloaded() {
    var session = SessionLease()
    let first = session.begin(at: now)!
    session.finish(.init(kind: .retrying), id: first, at: now, needsPageReload: true)
    XCTAssertTrue(session.needsPageReload)
    XCTAssertEqual(session.nextAttempt, now.addingTimeInterval(30))
    XCTAssertNil(session.begin(at: now.addingTimeInterval(300)))
    session.pageChanged(loginRequired: false)
    XCTAssertFalse(session.needsPageReload)
    let second = session.begin(at: now.addingTimeInterval(300))!
    session.finish(.init(kind: .active), id: first, at: now)
    XCTAssertEqual(session.attempt, second)
    XCTAssertEqual(session.successCount, 0)
    session.finish(.init(kind: .active), id: second, at: now.addingTimeInterval(300))
    XCTAssertEqual(session.successCount, 1)
  }
  func testRepeatedTimeoutAndReloadKeepExponentialBackoff() {
    var session = SessionLease()
    var time = now
    for delay in [30.0, 60, 120, 240, 300] {
      let id = session.begin(at: time)!
      session.finish(.init(kind: .retrying), id: id, at: time, needsPageReload: true)
      XCTAssertEqual(session.nextAttempt, time.addingTimeInterval(delay))
      XCTAssertFalse(session.canReloadPage(at: time, downloadInProgress: false))
      time = time.addingTimeInterval(delay)
      XCTAssertFalse(session.canReloadPage(at: time, downloadInProgress: true))
      XCTAssertTrue(session.canReloadPage(at: time, downloadInProgress: false))
      session.pageChanged(loginRequired: false)
    }
    let id = session.begin(at: time)!
    session.finish(.init(kind: .active), id: id, at: time)
    XCTAssertEqual(session.failureCount, 0)
  }
  func testUnsupportedRedirectsKeepCooldownUntilExplicitUserRetry() {
    var session = SessionLease()
    let id = session.begin(at: now)!
    session.finish(.init(kind: .unsupported, code: 401), id: id, at: now)
    // Official 401 sends the page through index.html and back to module.html.
    session.pageChanged(loginRequired: false)
    session.pageChanged(loginRequired: false)
    XCTAssertEqual(session.state, .unsupported)
    XCTAssertEqual(session.nextAttempt, now.addingTimeInterval(300))
    XCTAssertNil(session.begin(at: now.addingTimeInterval(10)))
    session.pageChanged(loginRequired: false, userInitiated: true)
    XCTAssertNotNil(session.begin(at: now.addingTimeInterval(10)))
  }
  func testDownloadAuthorizationRejectionInvalidatesInFlightRenewal() {
    var session = SessionLease()
    let first = session.begin(at: now)!
    session.finish(.init(kind: .active), id: first, at: now)
    XCTAssertFalse(session.rejectDownload(statusCode: 404))
    XCTAssertEqual(session.state, .active)
    let renewal = session.begin(at: now.addingTimeInterval(60))!
    XCTAssertTrue(session.rejectDownload(statusCode: 403))
    session.finish(.init(kind: .active), id: renewal, at: now.addingTimeInterval(60))
    XCTAssertEqual(session.state, .loginRequired)
    XCTAssertEqual(session.responseCode, 403)
    XCTAssertNil(session.begin(at: now.addingTimeInterval(9999)))
  }
  func testScanReplyFromOldPageCannotBecomeValidAfterNewPageRenews() throws {
    var session = SessionLease()
    let id = session.begin(at: now)!
    session.finish(.init(kind: .active), id: id, at: now)
    let oldPage = session.pageGeneration
    try session.validatePage(oldPage)
    session.pageChanged(loginRequired: false)
    let newID = session.begin(at: now)!
    session.finish(.init(kind: .active), id: newID, at: now)
    XCTAssertThrowsError(try session.validatePage(oldPage)) { error in
      XCTAssertEqual((error as? SessionAccessFailure)?.state, .unknown)
    }
    try session.validatePage(session.pageGeneration)
  }
  func testPageLoadFailureDuringUnsupportedCooldownStillReloadsWhenDue() {
    var session = SessionLease()
    let id = session.begin(at: now)!
    session.finish(.init(kind: .unsupported, code: 401), id: id, at: now)
    session.pageChanged(loginRequired: false)
    session.pageLoadFailed(at: now.addingTimeInterval(5))
    XCTAssertTrue(session.needsPageReload)
    XCTAssertEqual(session.nextAttempt, now.addingTimeInterval(300))
    XCTAssertFalse(session.canReloadPage(at: now.addingTimeInterval(299), downloadInProgress: false))
    XCTAssertTrue(session.canReloadPage(at: now.addingTimeInterval(300), downloadInProgress: false))
    session.pageChanged(loginRequired: false)
    let retry = session.begin(at: now.addingTimeInterval(300))!
    session.finish(.init(kind: .active), id: retry, at: now.addingTimeInterval(300))
    XCTAssertEqual(session.state, .active)
    XCTAssertFalse(session.needsPageReload)
  }
  func testUnexpectedAlbumToHomeRedirectWaitsButLoginReturnContinues() {
    var session = SessionLease()
    XCTAssertFalse(session.pageCommitted(path: "/login.html", at: now))
    XCTAssertFalse(session.pageCommitted(path: "/index.html", at: now))
    XCTAssertFalse(session.pageCommitted(path: "/module.html", at: now))
    let id = session.begin(at: now)!
    session.finish(.init(kind: .active, code: 200), id: id, at: now)
    // A list request can get 401 without passing through our renewal adapter.
    session.pageChanged(loginRequired: false)
    XCTAssertTrue(session.pageCommitted(path: "/index.html", at: now))
    XCTAssertEqual(session.state, .unsupported)
    XCTAssertNil(session.begin(at: now.addingTimeInterval(10)))
    XCTAssertTrue(session.canReloadPage(at: now.addingTimeInterval(300), downloadInProgress: false))
    session.pageChanged(loginRequired: false, userInitiated: true)
    XCTAssertFalse(session.pageCommitted(path: "/index.html", at: now))
  }
  func testPartiallyLoadedAlbumRedirectAlsoEntersCooldown() {
    var session = SessionLease()
    // The album document commits but subresources never finish before its startup request redirects.
    XCTAssertFalse(session.pageCommitted(path: "/module.html", at: now))
    session.pageChanged(loginRequired: false)
    XCTAssertTrue(session.pageCommitted(path: "/index.html", at: now.addingTimeInterval(3)))
    XCTAssertFalse(session.canReloadPage(at: now.addingTimeInterval(4), downloadInProgress: false))
    XCTAssertTrue(session.canReloadPage(at: now.addingTimeInterval(303), downloadInProgress: false))
    session.pageChanged(loginRequired: false)
    XCTAssertFalse(session.pageCommitted(path: "/module.html", at: now.addingTimeInterval(303)))
    session.pageChanged(loginRequired: false)
    XCTAssertTrue(session.pageCommitted(path: "/index.html", at: now.addingTimeInterval(306)))
    XCTAssertEqual(session.nextAttempt, now.addingTimeInterval(606))
  }
  func testWakeKeepsHomeRecoveryAndCooldownButInvalidatesOldRequest() {
    var session = SessionLease()
    _ = session.pageCommitted(path: "/module.html", at: now)
    let old = session.begin(at: now)!
    _ = session.pageCommitted(path: "/index.html", at: now)
    let generation = session.pageGeneration
    session.wakeUp()
    XCTAssertTrue(session.needsPageReload)
    XCTAssertNotEqual(session.pageGeneration, generation)
    XCTAssertEqual(session.nextAttempt, now.addingTimeInterval(300))
    XCTAssertFalse(session.canReloadPage(at: now.addingTimeInterval(100), downloadInProgress: false))
    XCTAssertTrue(session.canReloadPage(at: now.addingTimeInterval(300), downloadInProgress: false))
    session.finish(.init(kind: .active), id: old, at: now)
    XCTAssertEqual(session.state, .unsupported)
  }
  func testWakeRevalidatesPreviouslyActiveSessionImmediately() {
    var session = SessionLease()
    let id = session.begin(at: now)!
    session.finish(.init(kind: .active), id: id, at: now)
    session.wakeUp()
    XCTAssertEqual(session.state, .unknown)
    XCTAssertNotNil(session.begin(at: now.addingTimeInterval(1)))
  }
}
