import XCTest
@testable import SyncCore

final class ListRequestWaitTests: XCTestCase {
  func testBackoffAndNextEndpointExtendOnlyIdleDeadline() {
    var wait = ListRequestWait(startedAt: 0)
    wait.observe(activity: 1, at: 0)
    wait.observe(activity: 2, at: 29) // Backoff begins after a slow response.
    wait.observe(activity: 3, at: 59) // Next attempt after 30 seconds.
    XCTAssertFalse(wait.hasTimedOut(at: 88))
    wait.observe(activity: 4, at: 89) // Count completed; the list starts.
    XCTAssertFalse(wait.hasTimedOut(at: 120))
    XCTAssertTrue(wait.hasTimedOut(at: 134))
  }

  func testRepeatedOrStaleStateDoesNotRenewDeadline() {
    var wait = ListRequestWait(startedAt: 0)
    wait.observe(activity: 2, at: 1)
    wait.observe(activity: 2, at: 40)
    wait.observe(activity: 1, at: 44)
    XCTAssertTrue(wait.hasTimedOut(at: 46))
    XCTAssertTrue(ListRequestWait(startedAt: 0).hasTimedOut(at: 45))
  }

  func testContinuousActivityCannotExceedSixMinutes() {
    var wait = ListRequestWait(startedAt: 0)
    for n in 1...35 { wait.observe(activity: n, at: Double(n * 10)) }
    XCTAssertFalse(wait.hasTimedOut(at: 359))
    XCTAssertTrue(wait.hasTimedOut(at: 360))
  }
}
