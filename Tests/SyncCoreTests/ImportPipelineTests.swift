import XCTest
@testable import SyncCore

final class ImportPipelineTests: XCTestCase {
  @MainActor func testDownloadOverlapsImportButNeitherStageRunsTwice() async throws {
    var preparing = 0, consuming = 0, maximum = 0
    var didOverlap = false, consumed = [Int]()
    try await ImportPipeline.run(items: Array(0..<5), prepare: { value in
      preparing += 1
      XCTAssertEqual(preparing, 1)
      maximum = max(maximum, preparing + consuming)
      try await Task.sleep(nanoseconds: 5_000_000)
      didOverlap = didOverlap || consuming == 1
      preparing -= 1
      return value
    }, consume: { value in
      consuming += 1
      XCTAssertEqual(consuming, 1)
      maximum = max(maximum, preparing + consuming)
      try await Task.sleep(nanoseconds: 15_000_000)
      consumed.append(value)
      consuming -= 1
    })
    XCTAssertTrue(didOverlap)
    XCTAssertEqual(maximum, 2)
    XCTAssertEqual(consumed, Array(0..<5))
  }

  @MainActor func testOnlyOneItemCanBePrefetched() async throws {
    var prepared = 0, consumed = 0
    try await ImportPipeline.run(items: Array(0..<20), prepare: { value in
      prepared += 1
      XCTAssertLessThanOrEqual(prepared - consumed, 2)
      return value
    }, consume: { value in
      XCTAssertEqual(value, consumed)
      try await Task.sleep(nanoseconds: 1_000_000)
      consumed += 1
    })
    XCTAssertEqual(consumed, 20)
  }

  @MainActor func testPrepareFailureCancelsAndJoinsCurrentConsumer() async throws {
    var active = false, drained = false, calls = [Int]()
    do {
      try await ImportPipeline.run(items: [0, 1, 2], prepare: { value in
        calls.append(value)
        if value == 1 {
          while !active { await Task.yield() }
          throw SyncFailure("session expired")
        }
        return value
      }, consume: { _ in
        active = true
        defer { active = false; drained = true }
        try await Task.sleep(nanoseconds: 60_000_000_000)
      })
      XCTFail("failure ignored")
    } catch { XCTAssertEqual(error.localizedDescription, "session expired") }
    XCTAssertEqual(calls, [0, 1])
    XCTAssertFalse(active)
    XCTAssertTrue(drained)
  }

  @MainActor func testConsumerFailureJoinsInFlightDownloadBeforeReturning() async throws {
    var started = false, drained = false
    do {
      try await ImportPipeline.run(items: [0, 1, 2], prepare: { value in
        if value == 1 {
          started = true
          defer { drained = true }
          try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        return value
      }, consume: { _ in
        while !started { await Task.yield() }
        throw SyncFailure("storage failed")
      })
      XCTFail("failure ignored")
    } catch { XCTAssertEqual(error.localizedDescription, "storage failed") }
    XCTAssertTrue(drained)
  }

  @MainActor func testCancellationStartsNoWorkAndSourceFailureStopsNewPreparation() async throws {
    var started = 0
    let task = Task { @MainActor in
      try await ImportPipeline.run(items: [1, 2], prepare: { value in started += 1; return value }, consume: { _ in })
    }
    task.cancel()
    do { try await task.value; XCTFail("cancellation ignored") } catch is CancellationError {}
    XCTAssertEqual(started, 0)
    var canPrepare = true, handled = [Int]()
    try await ImportPipeline.run(items: [1, 2, 3], canPrepare: { canPrepare }, prepare: { value in
      canPrepare = false
      return value
    }, consume: { handled.append($0) })
    XCTAssertEqual(handled, [1])
  }

  func testProgressSeparatesFailureFromSuccessfulImport() {
    var progress = ImportProgress(total: 5)
    progress.finish(key: "a", state: .imported)
    progress.finish(key: "b", state: .duplicate)
    progress.finish(key: "c", state: .failed)
    progress.finish(key: "d", state: .importing)
    progress.finish(key: "d", state: .importing)
    XCTAssertEqual(progress.processed, 4)
    XCTAssertEqual(progress.imported, 1)
    XCTAssertEqual(progress.duplicates, 1)
    XCTAssertEqual(progress.failed, 2)
    XCTAssertEqual(progress.remaining, 1)
    XCTAssertEqual(progress.successful, 2)
  }
}
