import Foundation
import XCTest
@testable import SyncCore

final class DownloadProgressTests: XCTestCase {
  func testRollingSpeedAndStall() {
    var meter = DownloadSpeedMeter()
    XCTAssertNil(meter.sample(bytes: 0, at: 10))
    XCTAssertEqual(meter.sample(bytes: 500_000, at: 10.5)!, 1_000_000, accuracy: 1)
    XCTAssertEqual(meter.sample(bytes: 1_000_000, at: 11)!, 1_000_000, accuracy: 1)
    for i in 1...6 { _ = meter.sample(bytes: 1_000_000, at: 11 + Double(i) / 2) }
    XCTAssertEqual(meter.sample(bytes: 1_000_000, at: 14.5), 0)
  }

  func testRestartLongGapAndInvalidSamples() {
    var meter = DownloadSpeedMeter()
    XCTAssertNil(meter.sample(bytes: 5_000, at: 1))
    XCTAssertEqual(meter.sample(bytes: 6_000, at: 2), 1_000)
    XCTAssertNil(meter.sample(bytes: 0, at: 2.5))
    XCTAssertEqual(meter.sample(bytes: 500, at: 3), 1_000)
    XCTAssertNil(meter.sample(bytes: 50_000, at: 30))
    XCTAssertEqual(meter.sample(bytes: 50_500, at: 30.5), 1_000)
    XCTAssertNil(meter.sample(bytes: 50_500, at: 30.5))
    XCTAssertNil(meter.sample(bytes: -1, at: 31))
    XCTAssertNil(meter.sample(bytes: 0, at: .nan))
  }

  func testProgressWithUnknownOrInconsistentSize() {
    let unknown = DownloadProgress(filename: "sample.mov", receivedBytes: 3_000, totalBytes: 0)
    XCTAssertNil(unknown.fractionCompleted)
    let over = DownloadProgress(filename: "sample.jpg", receivedBytes: 120, totalBytes: 100)
    XCTAssertEqual(over.fractionCompleted, 1)
    XCTAssertEqual(over.receivedBytes, 120) // Do not hide a server size mismatch.
  }

  @MainActor func testMonitorClearsAndRejectsOldTransfers() async throws {
    let monitor = DownloadProgressMonitor()
    var updates = [DownloadProgress?]()
    monitor.onUpdate = { updates.append($0) }
    let old = UUID(), current = UUID()
    let first = Progress(totalUnitCount: 1_000)
    monitor.begin(token: old, filename: "first.jpg", totalBytes: 1_000)
    monitor.observe(first, token: old)
    first.completedUnitCount = 500
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(updates.last??.receivedBytes, 500)
    XCTAssertGreaterThan(updates.last??.bytesPerSecond ?? 0, 0)
    monitor.end(token: old)
    XCTAssertNil(updates.last!)
    let count = updates.count
    first.completedUnitCount = 1_000
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(updates.count, count)

    monitor.begin(token: current, filename: "second.mov", totalBytes: 10_000)
    monitor.observe(first, token: old)
    monitor.end(token: old)
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(updates.last??.filename, "second.mov")
    XCTAssertEqual(updates.last??.receivedBytes, 0)
    XCTAssertNil(updates.last??.bytesPerSecond)
    monitor.end(token: current)
    XCTAssertNil(updates.last!)
  }
}
